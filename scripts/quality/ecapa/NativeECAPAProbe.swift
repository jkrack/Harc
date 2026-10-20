import Foundation
import AVFoundation
import CoreML
struct Item:Decodable { let id:String;let audio:String;let startMs:Int;let endMs:Int? }
struct Corpus:Decodable {let cases:[Item]}
struct Row:Encodable {let id:String;let path:String;let frames:Int;let seconds:Double;let vector:[Float]}
@main struct Probe {
 static func main() throws {
  guard CommandLine.arguments.count==4 else {
   FileHandle.standardError.write(Data("Usage: native-ecapa-probe corpus.json output-directory model.mlpackage\n".utf8));exit(2)
  }
  let a=CommandLine.arguments, out=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let corpus=try JSONDecoder().decode(Corpus.self,from:Data(contentsOf:URL(fileURLWithPath:a[1])))
  let features=ECAPAFeatures();var rows:[Row]=[]
  let configuration=MLModelConfiguration();configuration.computeUnits = .cpuOnly
  let compiled=try MLModel.compileModel(at:URL(fileURLWithPath:a[3]))
  let model=try MLModel(contentsOf:compiled,configuration:configuration)
  for item in corpus.cases {
   let file=try AVAudioFile(forReading:URL(fileURLWithPath:item.audio),commonFormat:.pcmFormatFloat32,interleaved:false)
   guard file.processingFormat.sampleRate==16000,file.processingFormat.channelCount==1 else {throw ECAPAFeatures.Failure.invalidAudio}
   let first=Int64(item.startMs*16), last=min(file.length,item.endMs.map{Int64($0*16)} ?? file.length)
   guard first>=0,last-first>=32000,last-first<=480000 else {throw ECAPAFeatures.Failure.invalidAudio}
   file.framePosition=first
   let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(last-first))!
   var samples:[Float]=[]
   while samples.count<Int(last-first) {
    try file.read(into:buffer,frameCount:AVAudioFrameCount(Int(last-first)-samples.count))
    guard buffer.frameLength>0 else {throw ECAPAFeatures.Failure.invalidAudio}
    samples.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
   }
   let start=Date();let result=try features.extract(samples)
   let path=out.appendingPathComponent(String(format:"%03d.f32",rows.count))
   try result.withUnsafeBytes { try Data($0).write(to:path) }
   let array=try MLMultiArray(shape:[1,NSNumber(value:result.count/80),80],dataType:.float32)
   guard array.strides.map(\.intValue)==[result.count,80,1] else {throw ECAPAFeatures.Failure.invalidAudio}
   result.withUnsafeBufferPointer { array.dataPointer.assumingMemoryBound(to:Float.self).update(from:$0.baseAddress!,count:result.count) }
   let output=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["mel":MLFeatureValue(multiArray:array)]))
   guard let embedding=output.featureValue(for:"embedding")?.multiArrayValue,embedding.count==192 else {throw ECAPAFeatures.Failure.invalidAudio}
   let raw=(0..<192).map { embedding[$0].floatValue };let norm=sqrt(raw.reduce(Float(0)){$0+$1*$1})
   guard norm.isFinite,norm>0,raw.allSatisfy(\.isFinite) else {throw ECAPAFeatures.Failure.invalidAudio}
   rows.append(Row(id:item.id,path:path.path,frames:result.count/80,seconds:Date().timeIntervalSince(start),vector:raw.map{$0/norm}))
  }
  let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(rows).write(to:out.appendingPathComponent("results.json"))
 }
}
