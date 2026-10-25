"""Optional local compiler budget; hosted CI keeps its existing two workers."""
import os


def job_arguments(flag="--jobs"):
    jobs = os.environ.get("HARC_BUILD_JOBS", "")
    if not jobs and os.environ.get("CI") in ("true", "1"):
        jobs = "2"
    if jobs and (not jobs.isascii() or not jobs.isdecimal() or jobs.startswith("0")):
        raise ValueError("HARC_BUILD_JOBS must be a positive integer")
    return [flag, jobs] if jobs else []
