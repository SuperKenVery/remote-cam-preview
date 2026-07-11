import Observation

@MainActor
@Observable
final class AppDependencies {
    let wifiAware: WiFiAwareController
    let camera: CameraService
    let photoLibrary: PhotoLibraryService
    let mediaPipeline: MediaPipeline
    let photoResources: PhotoResourceStore

    init(
        wifiAware: WiFiAwareController? = nil,
        camera: CameraService? = nil,
        photoLibrary: PhotoLibraryService = PhotoLibraryService(),
        mediaPipeline: MediaPipeline? = nil,
        photoResources: PhotoResourceStore = PhotoResourceStore()
    ) {
        self.wifiAware = wifiAware ?? WiFiAwareController(photoResources: photoResources)
        self.camera = camera ?? CameraService()
        self.photoLibrary = photoLibrary
        self.mediaPipeline = mediaPipeline ?? MediaPipeline()
        self.photoResources = photoResources
    }
}
