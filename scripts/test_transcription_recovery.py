# Runs extracted production control flow with simulated recognition and real AVFoundation exports.
# Does not contact a recognition service or use patient audio.
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
p='Sources/SpeechSessionFeatures/RecordingViewModel.swift'
current=(root/p).read_text()
previous=subprocess.check_output(['git','show','0e37bdff0102ec212edbba5b12b0a069822926b7:'+p],cwd=root,text=True)
def function(src,name):
 start=src.index('    private func '+name)
 opening=src.index('{',start); depth=1; end=opening+1
 while depth:
  depth += (src[end]=='{')-(src[end]=='}'); end+=1
 return src[start:end].replace('private func','func',1)
base='''
 var live = ""
 var finalTranscriptIncomplete = false
 var errorMessage: String?
 var transcriptionStreamFinished = false
 var calls = 0
 var fail = true
 var isCaptureInterrupted = false
 var pauseBeganAt: Date?
 var totalPausedDuration: Double = 0
 func fullTranscriptForSave() -> String { live }
 func transcribeStoredRecordingFile(_ url: URL) async throws -> String {
 calls += 1
 if fail { throw TestError.failed }
 return "file transcript"
 }
'''
out='''import Foundation
import AVFoundation
enum TranscriptionBackend { case onDeviceApple, openAIWhisper }
enum TestError: Error { case failed }
enum AudioSessionEvent { case interruptionBegan, interruptionEnded(shouldResume: Bool), routeChanged, mediaServicesReset }
enum AudioFileTranscriptionError: Error { case emptyTranscript, openAIError(String), invalidServerResponse }
'''
for name,src in [('Current',current),('Previous',previous)]:
 out+='@MainActor final class '+name+' {\n'+base+function(src,'resolveFinalTranscript')+'\n'+function(src,'handleAudioSessionEvent')+'\n'+function(src,'resumeElapsedAfterPause')+'\n}\n'
segment=(root/'Sources/SpeechSessionTranscription/AudioFileTranscriptionService.swift').read_text()
out+=segment[segment.index('public struct PartialAudioTranscriptionError'):segment.index('public enum AudioFileTranscriptionService')]
out+=function(segment.replace('private static func','private func'),'transcribeSegments')+'\n'
out+='''
@main struct Audit {
 @MainActor static func main() async throws {
 let file=URL(fileURLWithPath:"/tmp/transcription-audit/silence.caf")
 let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
 do {
 let audio=try AVAudioFile(forWriting:file,settings:format.settings)
 let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
 buffer.frameLength=16000
 memset(buffer.floatChannelData![0],0,16000*MemoryLayout<Float>.size)
 for _ in 0..<100 { try audio.write(from:buffer) }
 }
 let c=Current(); c.live="successful live transcript"
 let p=Previous(); p.live=c.live
 let ct=await c.resolveFinalTranscript(recordingFileURL:file,backend:.onDeviceApple,wasWhisper:false)
 let pt=await p.resolveFinalTranscript(recordingFileURL:file,backend:.onDeviceApple,wasWhisper:false)
 print("APPLE current: fileCalls=\\(c.calls), incomplete=\\(c.finalTranscriptIncomplete), text=\\(ct)")
 print("APPLE baseline: fileCalls=\\(p.calls), incomplete=\\(p.finalTranscriptIncomplete), text=\\(pt)")
 precondition(c.calls==0 && !c.finalTranscriptIncomplete && p.calls==0 && pt==ct)
 let wc=Current(); let wp=Previous()
 Task { @MainActor in
 try? await Task.sleep(nanoseconds:200_000_000)
 wc.live="batch success"; wp.live="batch success"
 }
 let wct=await wc.resolveFinalTranscript(recordingFileURL:file,backend:.openAIWhisper,wasWhisper:true)
 let wpt=await wp.resolveFinalTranscript(recordingFileURL:file,backend:.openAIWhisper,wasWhisper:true)
 print("WHISPER current returned=\\(String(reflecting:wct)); baseline returned=\\(String(reflecting:wpt))")
 precondition(wct=="batch success" && wpt=="batch success" && !wc.finalTranscriptIncomplete)
 c.handleAudioSessionEvent(.interruptionBegan)
 c.handleAudioSessionEvent(.interruptionEnded(shouldResume:false))
 p.handleAudioSessionEvent(.interruptionBegan)
 p.handleAudioSessionEvent(.interruptionEnded(shouldResume:false))
 print("INTERRUPTION shouldResume=false: current paused=\\(c.isCaptureInterrupted); baseline paused=\\(p.isCaptureInterrupted)")
 precondition(c.isCaptureInterrupted && !p.isCaptureInterrupted)
 var calls=0
 let successful=try await transcribeSegments(fileURL:file,maximumDuration:45) { _ in
 calls+=1; return "segment \\(calls)"
 }
 print("SEGMENTS success: calls=\\(calls); text=\\(successful.replacingOccurrences(of:"\\n",with:" | "))")
 precondition(calls==3)
 calls=0
 do {
 _ = try await transcribeSegments(fileURL:file,maximumDuration:45) { _ in
 calls+=1
 if calls==2 || calls==3 { throw AudioFileTranscriptionError.emptyTranscript }
 return "successful first segment"
 }
 fatalError("Expected reproduction of whole-record failure")
 } catch {
 print("SEGMENTS empty second segment: entire call threw \\(error), calls=\\(calls), partial result retained")
 precondition(calls==4)
 let partial = error as! PartialAudioTranscriptionError
 precondition(partial.transcript.contains("Audio 0–45") && partial.transcript.contains("Audio 86–100"))
 }
 calls=0
 let retried=try await transcribeSegments(fileURL:file,maximumDuration:45) { _ in
 calls+=1
 if calls==2 { throw TestError.failed }
 return "recovered"
 }
 precondition(calls==4 && retried.contains("Audio 43–88"))
 calls=0
 do {
 _ = try await transcribeSegments(fileURL:file,maximumDuration:45) { _ in
 calls+=1
 if calls==2 { throw CancellationError() }
 return "saved before cancellation"
 }
 fatalError("Expected cancellation")
 } catch {
 precondition(calls==2 && (error as? PartialAudioTranscriptionError)?.transcript.contains("saved before cancellation") == true)
 }
 print("PASS: all seven recovery scenarios passed. No speech service called.")
 }
}
'''
import tempfile
with tempfile.TemporaryDirectory(prefix='transcription-recovery-') as directory:
 source=Path(directory)/'Audit.swift'
 out=out.replace('/tmp/transcription-audit/silence.caf', str(Path(directory)/'silence.caf'))
 source.write_text(out)
 executable=Path(directory)/'audit'
 subprocess.run(['swiftc','-module-cache-path',str(Path(directory)/'cache'),'-parse-as-library',str(source),'-o',str(executable)],check=True)
 subprocess.run([str(executable)],check=True)
