import Foundation

public final class ImagePipeline {
    public static let shared = ImagePipeline()

    private let fetcher: Fetching
    private let decoder: Decoding
    private let diskCache: DataCaching
    private let memoryCache: ImageCaching

    private let queue = DispatchQueue.init(label: "com.folio-sec.image-pipeline", qos: .userInitiated)
    private var controllers = [ImageViewReference: ImageViewController]()

    private class ImageViewController {
        weak var imageView: UIImageView?
        let url: URL

        init(imageView: UIImageView, url: URL) {
            self.imageView = imageView
            self.url = url
        }
    }

    public init(fetcher: Fetching = Fetcher(), decoder: Decoding = Decoder(), diskCache: DataCaching = DiskCache(), memoryCache: ImageCaching = MemoryCache()) {
        self.fetcher = fetcher
        self.decoder = decoder
        self.diskCache = diskCache
        self.memoryCache = memoryCache
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning(notification:)), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground(notification:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    public func load(_ url: URL, into imageView: UIImageView, transition: Transition = .none, defaultImage: UIImage? = nil, failureImage: UIImage? = nil) {
        imageView.image = defaultImage

        if let image = memoryCache.load(for: url) {
            imageView.image = image
            return
        }
        if let entry = diskCache.load(for: url) {
            if let ttl = entry.timeToLive {
                let expirationDate = entry.modificationDate.addingTimeInterval(ttl)
                if expirationDate  > Date(), let image = decoder.decode(data: entry.data) {
                    self.memoryCache.store(image, for: url)
                    imageView.image = image
                    return
                }
            } else if let image = decoder.decode(data: entry.data) {
                self.memoryCache.store(image, for: url)
                imageView.image = image
                return
            }
        }

        queue.async { [weak self] in
            guard let self = self else {
                return
            }

            let reference = ImageViewReference(imageView)
            self.controllers[reference] = ImageViewController(imageView: imageView, url: url)
            
            self.fetcher.fetch(url, completion: { [weak self] in
                guard let self = self else {
                    return
                }

                guard let image = self.decoder.decode(data: $0.data) else {
                    DispatchQueue.main.async {
                        self.setImage(failureImage, for: url, into: imageView, transition: transition)
                    }
                    return
                }

                self.diskCache.store($0, for: url)
                self.memoryCache.store(image, for: url)

                DispatchQueue.main.async {
                    self.setImage(image, for: url, into: imageView, transition: transition)
                }
            }, cancellation: {
                /* do nothing */
            }, failure: { [weak self] _ in
                guard let self = self else {
                    return
                }
                DispatchQueue.main.async {
                    self.setImage(failureImage, for: url, into: imageView, transition: transition)
                }
            })
        }
    }

    private func setImage(_ image: UIImage?, for url: URL, into imageView: UIImageView, transition: Transition) {
        if let controller = controllers[ImageViewReference(imageView)], controller.imageView != nil, controller.url == url {
            switch transition.style {
            case .none:
                imageView.image = image
            case .fadeIn(let duration):
                UIView.transition(with: imageView, duration: duration, options: [.transitionCrossDissolve], animations: {
                    imageView.image = image
                })
            }
        }
    }

    @objc
    private func didReceiveMemoryWarning(notification: Notification) {
        memoryCache.removeAll()
    }

    @objc
    private func didEnterBackground(notification: Notification) {
        diskCache.removeOutdated()
        diskCache.compact()
    }

    private class ImageViewReference: Hashable {
        weak var imageView: UIImageView?
        let objectIdentifier: ObjectIdentifier

        init(_ imageView: UIImageView) {
            self.imageView = imageView
            objectIdentifier = ObjectIdentifier(imageView)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(objectIdentifier)
        }

        static func == (lhs: ImagePipeline.ImageViewReference, rhs: ImagePipeline.ImageViewReference) -> Bool {
            return lhs.objectIdentifier == rhs.objectIdentifier
        }
    }
}
