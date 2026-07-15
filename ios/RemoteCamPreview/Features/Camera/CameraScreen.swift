import AVFoundation
import SwiftUI

struct CameraScreen: View {
    let session: AppSession
    let camera: CameraService

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                CameraPreviewView(session: camera.captureSession)
                    .ignoresSafeArea(edges: .horizontal)

                if let error = camera.authorizationMessage {
                    Text(error)
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial, in: .rect(cornerRadius: 10))
                        .padding()
                }

                CameraZoomControls(camera: camera)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            ZStack {
                Color.black
                Button {
                    Task { await session.capturePhoto() }
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 72, height: 72)
                        Circle().stroke(.black.opacity(0.65), lineWidth: 3).frame(width: 62, height: 62)
                    }
                }
                .disabled(!camera.isReady || camera.isCapturingPhoto)
                .opacity(camera.isReady && !camera.isCapturingPhoto ? 1 : 0.45)
                .accessibilityLabel("拍照")
                .accessibilityIdentifier("camera.shutter")

                HStack {
                    Spacer()
                    Button {
                        session.switchCamera()
                    } label: {
                        Image(systemName: "camera.rotate.fill")
                            .font(.title2)
                            .frame(width: 48, height: 48)
                            .foregroundStyle(.white)
                            .background(.white.opacity(0.14), in: .circle)
                    }
                    .disabled(!camera.canSwitchCamera || camera.isCapturingPhoto)
                    .opacity(camera.canSwitchCamera && !camera.isCapturingPhoto ? 1 : 0.4)
                    .accessibilityLabel("翻转前后摄像头")
                    .accessibilityIdentifier("camera.flip")
                    .padding(.trailing, 24)
                }
            }
            .frame(height: 124)
        }
        .background(.black)
    }
}

private struct CameraZoomControls: View {
    let camera: CameraService

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(camera.zoomPresets, id: \.self) { factor in
                    Button {
                        camera.setZoomFactor(factor)
                    } label: {
                        Text(Self.factorLabel(factor))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected(factor) ? .black : .white)
                            .frame(minWidth: 42, minHeight: 34)
                            .background(
                                isSelected(factor) ? Color.yellow : Color.black.opacity(0.55),
                                in: .capsule
                            )
                    }
                    .accessibilityLabel("切换到 \(Self.factorLabel(factor)) 变焦")
                    .accessibilityIdentifier("camera.zoomPreset.\(factor)")
                }
            }

            HStack(spacing: 10) {
                Text(Self.factorLabel(camera.zoomFactor))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, alignment: .trailing)

                Slider(value: zoomPosition, in: 0...1)
                    .tint(.yellow)
                    .accessibilityLabel("连续变焦")
                    .accessibilityValue(Self.factorLabel(camera.zoomFactor))
                    .accessibilityIdentifier("camera.zoomSlider")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.42), in: .rect(cornerRadius: 16))
        .disabled(!camera.isReady)
    }

    private var zoomPosition: Binding<Double> {
        Binding(
            get: {
                let minimum = Double(camera.zoomRange.lowerBound)
                let maximum = Double(camera.zoomRange.upperBound)
                guard maximum > minimum else { return 0 }
                return log(Double(camera.zoomFactor) / minimum) / log(maximum / minimum)
            },
            set: { position in
                let minimum = Double(camera.zoomRange.lowerBound)
                let maximum = Double(camera.zoomRange.upperBound)
                guard maximum > minimum else { return }
                camera.setZoomFactor(CGFloat(minimum * pow(maximum / minimum, position)))
            }
        )
    }

    private func isSelected(_ factor: CGFloat) -> Bool {
        abs(camera.zoomFactor - factor) < 0.06
    }

    private static func factorLabel(_ factor: CGFloat) -> String {
        let rounded = factor.rounded()
        if abs(factor - rounded) < 0.05 {
            return String(format: "%.0f×", rounded)
        }
        return String(format: "%.1f×", factor)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.previewLayer.session = session
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
