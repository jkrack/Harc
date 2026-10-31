#!/usr/bin/env python3
"""Run TLS identity regressions without unrelated MLX/Metal targets.

Default includes the real 50-cycle Network.framework listener test.
--identity-only explicitly excludes that test; it does not qualify listeners.
The second phase runs two built test processes concurrently (no SwiftPM lock).
This is not an installed app + harc-mcp launch qualification.
"""
import argparse
from build_concurrency import job_arguments
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--identity-only", action="store_true")
args = parser.parse_args()
try:
    build_jobs = job_arguments("--jobs")
except ValueError as error:
    parser.error(str(error))
repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="harc-tls-regression-") as scratch:
    root = Path(scratch)
    for parent, names in [("Sources", ["HarcDomain", "HarcIdentity"]),
                          ("Tests", ["HarcIdentityTests", "HarcTestSupport"])]:
        (root / parent).mkdir()
        for name in names:
            (root / parent / name).symlink_to(repo / parent / name)
    (root / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HarcTLSRegression", platforms: [.macOS(.v26)], targets: [
 .target(name: "HarcDomain", exclude: ["README.md"]),
 .target(name: "HarcIdentity", dependencies: ["HarcDomain"], exclude: ["README.md"]),
 .target(name: "HarcTestSupport", path: "Tests/HarcTestSupport"),
 .testTarget(name: "HarcIdentityTests", dependencies: ["HarcIdentity", "HarcDomain", "HarcTestSupport"], resources: [.copy("Fixtures")])
])
''')
    command = ["swift", "test", "--package-path", scratch, "--build-system", "native",
               *build_jobs, "--filter",
               "HostTLSServerIdentityTests" if args.identity_only else
               "HostTLSServerIdentityTests|ListenerTestCycleTests"]
    if args.identity_only:
        print("Listener qualification explicitly excluded.", flush=True)
        command += ["--skip", "listenerRestartsDoNotInstallCertificates"]
    subprocess.run(command, check=True)
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    helper = swift.parents[1] / "libexec/swift/pm/swiftpm-testing-helper"
    bundles = list((root / ".build").glob("*/debug/HarcTLSRegressionPackageTests.xctest/Contents/MacOS/HarcTLSRegressionPackageTests"))
    if len(bundles) != 1:
        raise RuntimeError("Expected exactly one native test bundle")
    platform = subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip()
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(Path(platform) / "Developer/Library/Frameworks"))
    command = [str(helper), "--test-bundle-path", str(bundles[0]), "--testing-library", "swift-testing", "--filter",
               "repeatedIdentityResolutionDoesNotInstallCertificates"]
    processes = []
    try:
        processes = [subprocess.Popen(command, env=env) for _ in range(2)]
        print("Concurrent test PIDs:", *(p.pid for p in processes), flush=True)
        results = [p.wait(timeout=60) for p in processes]
        if results != [0, 0]:
            raise RuntimeError(f"Concurrent identity regressions failed: {results}")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
