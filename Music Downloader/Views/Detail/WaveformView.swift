import AVFoundation
import SwiftUI

/// Renders an audio waveform from a file and provides interactive playback
/// with a scrubbing playhead.
struct WaveformView: View {
    let track: Track
    @Environment(PlaybackController.self) private var playback

    /// Downsampled amplitude data, one value per visual bucket. Range [0, 1].
    @State private var samples: [Float] = []
    @State private var isLoading = true

    /// Local scrub state so dragging doesn't fight with the 10 Hz timer.
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    /// Duration read from the file (used before playback starts).
    @State private var trackDuration: TimeInterval = 0

    /// Number of amplitude buckets to render.
    private let bucketCount = 300

    var body: some View {
        VStack(spacing: 4) {
            waveformArea
            timeLabels
        }
        .task(id: track.fileURL) {
            await loadSamples()
        }
    }

    // MARK: - Waveform area

    private var waveformArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    waveformPath(in: geo.size)
                    playheadLine(width: geo.size.width)
                }

                HStack {
                    playPauseButton
                    Spacer()
                }
                .padding(.leading, 8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = max(0, min(1, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        if !playback.isCurrent(track) {
                            playback.play(track)
                        }
                        playback.seek(to: fraction * playback.duration)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 100)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func waveformPath(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let mid = h / 2

        return Path { path in
            guard !samples.isEmpty else { return }
            let barWidth = w / CGFloat(samples.count)
            for (i, amplitude) in samples.enumerated() {
                let x = CGFloat(i) * barWidth + barWidth / 2
                let barHeight = CGFloat(amplitude) * mid * 0.9
                path.move(to: CGPoint(x: x, y: mid - barHeight))
                path.addLine(to: CGPoint(x: x, y: mid + barHeight))
            }
        }
        .stroke(Color.primary.opacity(0.6), lineWidth: max(1, w / CGFloat(max(samples.count, 1)) * 0.6))
    }

    private func playheadLine(width: CGFloat) -> some View {
        let fraction = isScrubbing
            ? scrubFraction
            : (playback.duration > 0 && playback.isCurrent(track)
                ? playback.currentTime / playback.duration
                : 0)

        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .offset(x: fraction * width)
    }

    // MARK: - Play/pause button

    private var playPauseButton: some View {
        Button {
            playback.toggle(track)
        } label: {
            Image(systemName: playback.isPlaying(track) ? "pause.fill" : "play.fill")
                .font(.system(size: 28))
                .foregroundStyle(.primary)
                .shadow(color: .black.opacity(0.3), radius: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Time labels

    private var timeLabels: some View {
        HStack {
            Text(format(currentDisplayTime))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("Duration: \(format(playback.isCurrent(track) ? playback.duration : trackDuration))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("-\(format(remaining))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var currentDisplayTime: TimeInterval {
        guard playback.isCurrent(track) else { return 0 }
        return isScrubbing ? scrubFraction * playback.duration : playback.currentTime
    }

    private var remaining: TimeInterval {
        guard playback.isCurrent(track) else { return trackDuration }
        let dur = playback.duration
        let cur = isScrubbing ? scrubFraction * dur : playback.currentTime
        return max(0, dur - cur)
    }

    // MARK: - Sample loading

    private func loadSamples() async {
        guard let url = track.fileURL else {
            isLoading = false
            return
        }

        // Read duration for labels even before playback.
        if let player = try? AVAudioPlayer(contentsOf: url) {
            trackDuration = player.duration
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)

            guard frameCount > 0 else {
                isLoading = false
                return
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                isLoading = false
                return
            }
            try file.read(into: buffer)

            guard let channelData = buffer.floatChannelData?[0] else {
                isLoading = false
                return
            }

            let total = Int(buffer.frameLength)
            let framesPerBucket = max(1, total / bucketCount)
            var result = [Float]()
            result.reserveCapacity(bucketCount)

            for bucket in 0..<bucketCount {
                let start = bucket * framesPerBucket
                let end = min(start + framesPerBucket, total)
                var maxAmp: Float = 0
                for i in start..<end {
                    let val = abs(channelData[i])
                    if val > maxAmp { maxAmp = val }
                }
                result.append(maxAmp)
            }

            // Normalize to [0, 1]
            let peak = result.max() ?? 1
            if peak > 0 {
                result = result.map { $0 / peak }
            }

            await MainActor.run {
                samples = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
        }
    }

    // MARK: - Formatting

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
