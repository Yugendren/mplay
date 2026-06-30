// mplay-srate — match the current default output device to a track's sample rate.
//
//   mplay-srate <sample_rate_hz>
//
// Sets the default output device's nominal sample rate to <sample_rate_hz> so
// CoreAudio stops resampling (the kHz fix). Then best-effort upgrades the
// device's *physical format* to the highest bit depth it offers at that rate
// (e.g. prefer 32-bit over 24/16). The physical-format change is allowed to
// fail silently: many devices reject it in shared mode without exclusive/hog
// access, in which case the nominal-rate change alone is the meaningful fix.
//
// Exit codes: 0 = nominal rate set (bit-depth upgrade is best-effort and never
// fails the program), 1 = bad args / no device / could not set rate.

import CoreAudio
import AudioToolbox
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("mplay-srate: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count == 2, let target = Double(CommandLine.arguments[1]), target > 0 else {
    fail("usage: mplay-srate <sample_rate_hz>")
}

// --- resolve the current default output device ---
var devID = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) != noErr
    || devID == 0 {
    fail("no default output device")
}

// --- set nominal sample rate (the core fix) ---
var rate = target
addr.mSelector = kAudioDevicePropertyNominalSampleRate
addr.mScope = kAudioObjectPropertyScopeOutput

// Only change it if it actually differs, to avoid a needless glitch.
var current: Double = 0
var rsize = UInt32(MemoryLayout<Double>.size)
if AudioObjectGetPropertyData(devID, &addr, 0, nil, &rsize, &current) == noErr,
   abs(current - target) < 1.0 {
    // already matched — still try the bit-depth upgrade below.
} else {
    let st = AudioObjectSetPropertyData(devID, &addr, 0, nil,
                                        UInt32(MemoryLayout<Double>.size), &rate)
    if st != noErr {
        fail("could not set sample rate to \(Int(target)) Hz (status \(st))")
    }
}

// --- best-effort: pick the highest bit depth available at this rate ---
// Enumerate the output stream's available physical formats, keep those whose
// sample rate matches the target, choose the one with the largest
// mBitsPerChannel, and set it. Any failure here is non-fatal.
func upgradeBitDepth(_ dev: AudioDeviceID, rate: Double) {
    var sAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var sSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { return }
    let count = Int(sSize) / MemoryLayout<AudioStreamID>.size
    var streams = [AudioStreamID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(dev, &sAddr, 0, nil, &sSize, &streams) == noErr,
          let stream = streams.first else { return }

    var fAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var fSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(stream, &fAddr, 0, nil, &fSize) == noErr, fSize > 0 else { return }
    let n = Int(fSize) / MemoryLayout<AudioStreamRangedDescription>.size
    var formats = [AudioStreamRangedDescription](
        repeating: AudioStreamRangedDescription(), count: n)
    guard AudioObjectGetPropertyData(stream, &fAddr, 0, nil, &fSize, &formats) == noErr else { return }

    var best: AudioStreamBasicDescription? = nil
    for f in formats {
        let asbd = f.mFormat
        // match the sample rate (0 means "any" in some ranged descriptors)
        if asbd.mSampleRate != 0 && abs(asbd.mSampleRate - rate) >= 1.0 { continue }
        if best == nil || asbd.mBitsPerChannel > best!.mBitsPerChannel {
            best = asbd
        }
    }
    guard var chosen = best else { return }
    if chosen.mSampleRate == 0 { chosen.mSampleRate = rate }

    var pAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyPhysicalFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    _ = AudioObjectSetPropertyData(stream, &pAddr, 0, nil,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &chosen)
}

upgradeBitDepth(devID, rate: target)
exit(0)
