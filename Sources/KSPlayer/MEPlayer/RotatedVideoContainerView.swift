#if canImport(UIKit)
import UIKit

/// Keeps presentation rotation separate from the view KSPlayer sizes to its viewport.
///
/// `AVSampleBufferDisplayLayer` calculates aspect-fit/aspect-fill before its host view's
/// transform is applied. A quarter-turn therefore needs a renderer whose untransformed
/// bounds have the viewport's width and height swapped.
final class RotatedVideoContainerView: UIView {
    let contentView: UIView

    var rotationDegrees = 0.0 {
        didSet {
            guard rotationDegrees != oldValue else { return }
            setNeedsLayout()
        }
    }

    init(contentView: UIView) {
        self.contentView = contentView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(contentView)
        contentView.contentMode = contentMode
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var contentMode: UIView.ContentMode {
        didSet {
            contentView.contentMode = contentMode
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let contentSize = Self.rotationSwapsAxes(rotationDegrees)
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size

        contentView.transform = .identity
        contentView.bounds = CGRect(origin: .zero, size: contentSize)
        contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        contentView.transform = CGAffineTransform(
            rotationAngle: CGFloat(rotationDegrees * .pi / 180)
        )
    }

    static func rotationSwapsAxes(_ degrees: Double) -> Bool {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return abs(positive - 90) < 0.001 || abs(positive - 270) < 0.001
    }
}
#endif
