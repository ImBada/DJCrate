import AppKit
import Foundation
import Testing
import DJCTestSupport
import DJCDomain
@testable import DJCAnalysis
@testable import DJCrate

struct ColorWaveformRasterTests {
    static var waveform: Waveform {
        Waveform(rate: 2, duration: 2, low: [0, 255, 0, 80], mid: [0, 0, 255, 40], high: [0, 0, 0, 160])
    }

    @Test func fallbackUsesAudioTimelineAndBandColors() throws {
        for mode in [WaveformColorMode.blue, .rgb] {
            let raster = try #require(ColorWaveformRaster.load(waveform: Self.waveform, datURL: nil,
                                                               mode: mode, audioOffset: 0.04))
            #expect(raster.offset == 0.04)
            #expect(raster.rate == 2)
            #expect(raster.duration == 2)
            #expect(raster.detail.width == 4)
            let bitmap = NSBitmapImageRep(cgImage: raster.detail)
            #expect(bitmap.colorAt(x: 0, y: 64)?.alphaComponent == 0)
            let low = try #require(bitmap.colorAt(x: 1, y: 64))
            if mode == .rgb { #expect(low.redComponent > low.blueComponent) }
            else { #expect(low.blueComponent > low.redComponent) }
        }
    }

    @Test func analysisDetailAlreadyUsesRekordboxTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dat = root.appending(path: "ANLZ0000.DAT")
        try AnlzBuilder.file([AnlzBuilder.waveform("PWV3", entryBytes: 1, samples: Array(repeating: 31, count: 300))])
            .write(to: dat.deletingPathExtension().appendingPathExtension("EXT"))
        let raster = try #require(ColorWaveformRaster.load(waveform: Self.waveform, datURL: dat, mode: .blue, audioOffset: 0.04))
        #expect(raster.offset == 0)
        #expect(raster.rate == 150)
        #expect(raster.detail.width == 300)
        #expect(raster.duration == 2)
    }

    @Test @MainActor func changingModeDiscardsOldRasterAndCancelledResults() async throws {
        let deck = DeckModel(audio: FakeDeckAudio(), storage: .memory(MemoryDrafts()), runsAnalysis: false)
        deck.waveform = Self.waveform
        deck.waveformColorMode = .rgb
        await deck.colorWaveformTask?.value
        #expect(deck.colorWaveform != nil)
        deck.waveformColorMode = .blue
        let pending = deck.colorWaveformTask
        deck.waveformColorMode = .threeBand
        await pending?.value
        #expect(deck.colorWaveform == nil)
        deck.waveformColorMode = .rgb
        deck.waveform = nil
        await deck.colorWaveformTask?.value
        #expect(deck.colorWaveform == nil)
    }
}
