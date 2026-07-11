import AVFoundation
import SwiftUI

struct CameraScreen: View {
    let session: AppSession
    let camera: CameraService

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(session: camera.captureSession)
                .ignoresSafeArea(edges: .horizontal)

            VStack(spacing: 12) {
                if let error = camera.authorizationMessage {
                    Text(error)
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial, in: .rect(cornerRadius: 10))
                }

                Button {
                    Task { await session.capturePhoto() }
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 72, height: 72)
                        Circle().stroke(.black.opacity(0.65), lineWidth: 3).frame(width: 62, height: 62)
                    }
                }
                .disabled(!camera.isReady || camera.isCapturingPhoto)
                .accessibilityLabel("拍照")
                .accessibilityIdentifier("camera.shutter")
            }
            .padding(.bottom, 24)
        }
        .background(.black)
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

