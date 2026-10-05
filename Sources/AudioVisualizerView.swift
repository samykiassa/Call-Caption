import AppKit

public enum VisualizerMode {
    case waveform(barCount: Int)
    case equalizer(barCount: Int)
}

public class AudioVisualizerView: NSView {
    private var bars: [CALayer] = []
    private var mode: VisualizerMode
    private var currentLevel: Float = 0.0
    private var ambientTimer: Timer?
    private var ambientPhase: CGFloat = 0.0
    
    public var tintColor: NSColor = NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0) {
        didSet {
            updateColors()
        }
    }
    
    public init(frame frameRect: NSRect, mode: VisualizerMode = .equalizer(barCount: 5)) {
        self.mode = mode
        super.init(frame: frameRect)
        setupLayers()
        startAmbientAnimationIfNeeded()
    }
    
    public override init(frame frameRect: NSRect) {
        self.mode = .equalizer(barCount: 5)
        super.init(frame: frameRect)
        setupLayers()
    }
    
    public required init?(coder: NSCoder) {
        self.mode = .equalizer(barCount: 5)
        super.init(coder: coder)
        setupLayers()
    }
    
    deinit {
        ambientTimer?.invalidate()
    }
    
    public override func layout() {
        super.layout()
        setupLayers()
    }
    
    private func setupLayers() {
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        
        // Remove existing
        bars.forEach { $0.removeFromSuperlayer() }
        bars.removeAll()
        
        let count: Int
        let barWidth: CGFloat
        let spacing: CGFloat
        
        switch mode {
        case .waveform(let n):
            count = n
            barWidth = 3.2
            spacing = 3.2
        case .equalizer(let n):
            count = n
            barWidth = 2.5
            spacing = 2.0
        }
        
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2.0
        
        for i in 0..<count {
            let layer = CALayer()
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let initialH: CGFloat = initialHeight(for: i, total: count)
            let y = (bounds.height - initialH) / 2.0
            
            layer.frame = CGRect(x: x, y: y, width: barWidth, height: initialH)
            layer.cornerRadius = barWidth / 2.0
            layer.backgroundColor = tintColor.cgColor
            
            if case .waveform = mode {
                layer.shadowColor = tintColor.cgColor
                layer.shadowRadius = 5.0
                layer.shadowOpacity = 0.75
                layer.shadowOffset = .zero
            }
            
            self.layer?.addSublayer(layer)
            bars.append(layer)
        }
    }
    
    private func initialHeight(for index: Int, total: Int) -> CGFloat {
        switch mode {
        case .waveform:
            let progress = CGFloat(index) / CGFloat(max(1, total - 1))
            let bell = sin(progress * .pi)
            let baselineH = (bounds.height * 0.22) + (bounds.height * 0.70) * bell
            return max(4.0, baselineH)
        case .equalizer:
            let staggers: [CGFloat] = [4.5, 8.0, 13.0, 7.0]
            return staggers[index % staggers.count]
        }
    }
    
    private func updateColors() {
        for layer in bars {
            layer.backgroundColor = tintColor.cgColor
            if case .waveform = mode {
                layer.shadowColor = tintColor.cgColor
            }
        }
    }
    
    private func startAmbientAnimationIfNeeded() {
        if case .waveform = mode {
            ambientTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.currentLevel < 0.04 {
                    self.ambientPhase += 0.12
                    self.renderAmbientWave()
                }
            }
        }
    }
    
    private func renderAmbientWave() {
        guard case .waveform = mode else { return }
        let total = bars.count
        let maxHeight = bounds.height - 4
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)
        for (i, layer) in bars.enumerated() {
            let progress = CGFloat(i) / CGFloat(max(1, total - 1))
            let bell = sin(progress * .pi)
            let ripple = sin(ambientPhase + progress * 2.5 * .pi) * 0.18
            let factor = max(0.2, bell + ripple)
            let height = 4.0 + factor * (maxHeight - 4.0)
            let y = (bounds.height - height) / 2.0
            layer.frame = CGRect(x: layer.frame.origin.x, y: y, width: layer.frame.width, height: height)
        }
        CATransaction.commit()
    }
    
    public func setAudioLevel(_ level: Float) {
        currentLevel = level
        let maxHeight = bounds.height - 2
        let total = bars.count
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        
        for (i, layer) in bars.enumerated() {
            let progress = CGFloat(i) / CGFloat(max(1, total - 1))
            let bell = sin(progress * .pi)
            
            let factor: CGFloat
            switch mode {
            case .waveform:
                factor = 0.35 + 0.65 * bell
            case .equalizer:
                let factors: [Float] = [0.6, 0.9, 1.0, 0.75, 0.5]
                factor = CGFloat(factors[i % factors.count])
            }
            
            let baseH = initialHeight(for: i, total: total)
            let targetH = baseH + CGFloat(level) * factor * (maxHeight - baseH)
            let clampedH = min(maxHeight, max(baseH, targetH))
            let y = (bounds.height - clampedH) / 2.0
            
            layer.frame = CGRect(x: layer.frame.origin.x, y: y, width: layer.frame.width, height: clampedH)
            
            if level > 0.05 {
                layer.backgroundColor = tintColor.cgColor
                layer.shadowColor = tintColor.cgColor
                layer.shadowRadius = 5
                layer.shadowOpacity = 0.95
            } else if case .waveform = mode {
                layer.backgroundColor = tintColor.withAlphaComponent(0.85).cgColor
                layer.shadowOpacity = 0.6
            } else {
                layer.backgroundColor = tintColor.withAlphaComponent(0.85).cgColor
                layer.shadowColor = tintColor.cgColor
                layer.shadowRadius = 3
                layer.shadowOpacity = 0.6
            }
        }
        CATransaction.commit()
    }
}
