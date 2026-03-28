ProRAW拍照demo

ProRAW能力的检测与开启方式
1. 首先创建一个预设为`.photo`的`AVCaptureSession`，然后添加后置摄像头输入和`AVCapturePhotoOutput`
2. 然后调用`photoOutput.isAppleProRAWSupported`来获取该型号是否支持ProRAW
3. 如果支持的话，设`photoOutput.isAppleProRAWEnabled = true`然后再存储到一个变量里来决定后续ui的显示和拍摄模式
4. 最后在点击拍照后，如果支持ProRAW，创建的`AVCapturePhotoSettings`然后使用`photoOutput.availableRawPhotoPixelFormatTypes`里的`rawPixelFormatType`。如果不支持的话就使用默认的`AVCapturePhotoSettings()`

成片管线的主要步骤
1. 拍照，CameraManager.capturePhoto()
2. 通过 photo.fileDataRepresentation() 提取图像数据
3. 如果是proRAW, 用 CIRAWFilter(imageData:identifierHint:)解码成CIImage然后使用。如果是JPEG/HEIC, 直接使用CIImage
4. 接着先通过LUT_3D_SIZE来读取lut的尺寸。然后在每个pixel的rgb后加alpha=1.0，变成透明。再从float类型转成data。最后创建和设置对应的CIColorCubeWithColorSpace
5. 通过CIContext.createCGImage()渲染像素，再从CGImage转成UIImage
6. 最后保存到相册

遇到的主要问题及解决方式
1. 在我自己的iphone14上测试时，我用jpeg/heic模式拍摄的竖屏照片会在相册里以错误的朝向显示。这是因为调用CIContext.createCGImage()时抹除了原本EXIF里方向的数据。后来通过读取EXIF里的kCGImagePropertyOrientation，并在转成UIImage时重新应用在UIImage(cgImage:scale:orientation:）解决了问题。
2. 后来在另一台支持ProRAW的设备上测试竖屏拍照时，每次拍照都会在相册中保存两张照片，一张方向对，一张方向不对的。后来发现拍照设置中同时包含了rawPixelFormatType和hevc的format，导致didFinishProcessingPhoto被调用了两次，从而保存了两次。后来通过在保存前再检测一次photo.isRawPhoto解决了多余保存的问题。结果留下的那张照片方向仍然不对，因为发现`CIRAWFilter`在解码时已经自带了旋转和方向数据，不用像jpeg/heic照片一样最后额外添加exif里的方向数据。最后对于proraw和jpeg/heic照片分类做方向的处理就解决了。
