import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timelapse_app/Pages/VideoGridElement.dart';
import 'package:video_player/video_player.dart';

class HomePage extends StatefulWidget {
  final CameraDescription cameraDescription;
  const HomePage({super.key, required this.cameraDescription});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  CameraController? cameraController;
  Future<void>? initializeControllerFuture;
  Timer? captureTimer;
  int _imageCount = 0;
  bool _isRecording = false;
  bool _isProcessing = false;
  bool _isLoading = false;
  String timelapseType = "slow";
  String? sessionId;
  List<String> capturedVideosPath = [];
  VideoPlayerController? videoPlayerController;
  String? _generatedVideoPath;
  String? _latestImagePath;
  bool _isCameraInitialized = false;
  bool _hasPermission = false;
  List<AssetEntity> _videos = [];
  int? _playingIndex;
  VideoPlayerController? _currentVideoController;
  bool _isTimeLapseGenerated = false;
  bool _isVideoLoading = false;

  // Animation controllers
  late AnimationController _recordButtonController;
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializeApp();
    getGalleryImages();
  }

  void _initializeAnimations() {
    _recordButtonController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _recordButtonController, curve: Curves.easeInOut),
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initializeApp() async {
    await getUserPreferences();

    // Request camera permission first
    final cameraPermissionGranted = await requestPermission();

    if (!cameraPermissionGranted) {
      if (mounted) {
        _showSnackBar('Camera permission is required to use this app');
      }
      return;
    }

    // Add a small delay to ensure camera hardware is available after permission grant
    await Future.delayed(const Duration(milliseconds: 300));

    // Only initialize camera after permission is granted
    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (cameraController != null) {
      return; // Already initialized
    }

    cameraController = CameraController(
      widget.cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        print("Attempting to initialize camera (attempt ${retryCount + 1})...");
        await cameraController!.initialize();

        if (mounted) {
          setState(() {
            _isCameraInitialized = true;
          });
          print("Camera initialized successfully");
        }
        return; // Success, exit the retry loop
      } catch (e) {
        print('Error initializing camera (attempt ${retryCount + 1}): $e');
        retryCount++;

        if (retryCount < maxRetries) {
          // Wait before retrying
          await Future.delayed(Duration(milliseconds: 500 * retryCount));
        } else {
          // Final attempt failed
          if (mounted) {
            _showSnackBar(
              'Failed to initialize camera. Please restart the app.',
            );
          }
        }
      }
    }
  }

  Future<void> getUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString("SelectedValue");
    setState(() {
      timelapseType = data ?? 'slow';
    });
  }

  Future<bool> requestPermission() async {
    try {
      if (Platform.isAndroid) {
        if (await Permission.photos.isDenied) await Permission.photos.request();
        if (await Permission.videos.isDenied) await Permission.videos.request();
        if (await Permission.storage.isDenied)
          await Permission.storage.request();

        // Request camera permission and check if granted
        if (await Permission.camera.isDenied) {
          final status = await Permission.camera.request();
          if (status.isDenied || status.isPermanentlyDenied) {
            return false;
          }
        }

        // Check if camera permission is granted
        final cameraStatus = await Permission.camera.status;
        return cameraStatus.isGranted;
      } else if (Platform.isIOS) {
        if (await Permission.photos.isDenied) await Permission.photos.request();

        // Request camera permission and check if granted
        if (await Permission.camera.isDenied) {
          final status = await Permission.camera.request();
          if (status.isDenied || status.isPermanentlyDenied) {
            return false;
          }
        }

        // Check if camera permission is granted
        final cameraStatus = await Permission.camera.status;
        return cameraStatus.isGranted;
      }

      return true;
    } catch (e) {
      print("Error requesting permissions: $e");
      return false;
    }
  }

  Duration _getCaptureTimingsIntervals() {
    return timelapseType == 'fast'
        ? const Duration(milliseconds: 500)
        : const Duration(seconds: 5);
  }

  int _getFrameVideoRates() => 30;

  Future<void> startTimeLapse() async {
    HapticFeedback.mediumImpact();
    capturedVideosPath.clear();
    sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    setState(() {
      _isRecording = true;
      _imageCount = 0;
      _generatedVideoPath = null;
      _latestImagePath = null;
    });

    _recordButtonController.forward();
    await videoPlayerController?.dispose();
    videoPlayerController = null;

    final interval = _getCaptureTimingsIntervals();
    captureTimer = Timer.periodic(interval, (timer) async {
      await _captureImage();
    });
  }

  Future<void> getGalleryImages() async {
    setState(() {
      _isLoading = true;
    });
    final PermissionState permission =
        await PhotoManager.requestPermissionExtend();
    if (permission.isAuth) {
      setState(() {
        _hasPermission = true;
      });
    }
    // get the list of all the albums
    final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.video,
    );
    AssetPathEntity? timelapseAlbum;
    for (var album in albums) {
      final albumName = album.name;
      print("Found Album Name:$albumName");

      if (albumName == "TimeLapse Videos") {
        timelapseAlbum = album;
        break;
      }
    }
    List<AssetEntity> timeLapseVideos = [];
    if (timelapseAlbum != null) {
      final count = await timelapseAlbum.assetCountAsync;
      timeLapseVideos = await timelapseAlbum.getAssetListRange(
        start: 0,
        end: count,
      );
      // sort the videos on the basis of creation so that recent one will come in the first than the other one
      timeLapseVideos.sort(
        (a, b) => b.createDateTime.compareTo(a.createDateTime),
      );
      setState(() {
        _videos = timeLapseVideos;
        _isLoading = false;
      });
      if (mounted) {
        _showGalleryBottomSheet();
      }
    } else {
      setState(() {
        _videos = [];
        _isLoading = false;
      });
      if (mounted) {
        _showGalleryBottomSheet();
      }
    }
  }

  Future<void> playVideo(AssetEntity video, int index) async {
    HapticFeedback.lightImpact();

    if (_playingIndex == index && _currentVideoController != null) {
      if (_currentVideoController!.value.isPlaying) {
        await _currentVideoController!.pause();
      } else {
        await _currentVideoController!.play();
      }
      setState(() {});
      return;
    }

    _currentVideoController?.dispose();
    setState(() {
      _playingIndex = index;
      _currentVideoController = null;
      _isVideoLoading = true;
    });

    try {
      final file = await video.file;
      if (file != null && mounted) {
        final controller = VideoPlayerController.file(file);

        // Initialize the controller
        await controller.initialize();
        await controller.setLooping(true);

        if (mounted && _playingIndex == index) {
          setState(() {
            _currentVideoController = controller;
            _isVideoLoading = false;
          });
          await controller.play();
        } else {
          controller.dispose();
        }
      }
    } catch (e) {
      print('Error loading video: $e');
      if (mounted) {
        setState(() {
          _isVideoLoading = false;
          _playingIndex = null;
        });
        _showSnackBar('Failed to load video');
      }
    }
  }

  void _showDeleteDialog(
    AssetEntity video,
    int index,
    StateSetter setModalState,
  ) {
    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            "Delete Timelapse?",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          content: const Text(
            "This action cannot be undone.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white60),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _deleteVideo(video, index);
                if (mounted) {
                  setState(() {});
                  setModalState(() {});
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                "Delete",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showGalleryBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (context, scrollController) => Container(
            decoration: const BoxDecoration(
              color: Color(0xFF1C1C1E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: Column(
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      const Text(
                        'TIMELAPSE GALLERY',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: _videos.isEmpty
                      ? Center(
                          child: Text(
                            'No videos yet',
                            style: TextStyle(color: Colors.white),
                          ),
                        )
                      : GridView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                                childAspectRatio: 0.7,
                              ),
                          itemCount: _videos.length,
                          itemBuilder: (context, index) {
                            final isPlaying = _playingIndex == index;
                            final isLoading =
                                _isVideoLoading && _playingIndex == index;
                            return VideoGridItem(
                              video: _videos[index],
                              isPlaying: isPlaying,
                              isLoading: isLoading,
                              videoController: isPlaying
                                  ? _currentVideoController
                                  : null,
                              onTap: () async {
                                await playVideo(_videos[index], index);
                                setState(() {});
                                setModalState(() {});
                              },

                              onDelete: () => _showDeleteDialog(
                                _videos[index],
                                index,
                                setModalState,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteVideo(AssetEntity video, int index) async {
    try {
      final List<String> results = await PhotoManager.editor.deleteWithIds([
        video.id,
      ]);
      if (results.isNotEmpty) {
        if (_playingIndex == index) {
          await _currentVideoController?.dispose();
          _currentVideoController = null;
          _playingIndex = null;
        }
        setState(() {
          _videos.removeAt(index);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text("Timelapse deleted"),
              backgroundColor: const Color(0xFF2C2C2E),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      }
    } catch (e) {
      print("Error deleting video: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to delete: $e"),
            backgroundColor: Colors.red.withOpacity(0.8),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  void _stopTimeLapse() {
    HapticFeedback.mediumImpact();
    captureTimer?.cancel();
    setState(() {
      _isRecording = false;
    });
    _recordButtonController.reverse();

    if (capturedVideosPath.isNotEmpty) {
      _showGenerateVideoDialog();
    }
  }

  Future<void> _captureImage() async {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      print("Camera not initialized");
      return;
    }

    try {
      HapticFeedback.lightImpact();

      final directory = await getApplicationDocumentsDirectory();
      final sessionDir = Directory(
        path.join(directory.path, 'timelapse_${timelapseType}_$sessionId'),
      );

      if (!await sessionDir.exists()) {
        await sessionDir.create(recursive: true);
      }

      final paddedCount = _imageCount.toString().padLeft(5, '0');
      final imagePath = path.join(sessionDir.path, 'frame_$paddedCount.jpg');

      final image = await cameraController!.takePicture();
      await File(image.path).copy(imagePath);

      final savedFile = File(imagePath);
      if (await savedFile.exists()) {
        capturedVideosPath.add(imagePath);
        if (mounted) {
          setState(() {
            _imageCount++;
            _latestImagePath = imagePath;
          });
        }
      }
    } catch (e) {
      print("Error capturing image: $e");
    }
  }

  void _showGenerateVideoDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            "Timelapse Complete",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            'Captured $_imageCount frames. Generate video?',
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white60),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _generateVideo();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7C3AED),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text("Generate", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateVideo() async {
    if (capturedVideosPath.isEmpty) {
      _showSnackBar("No images to process");
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final directory = await getApplicationDocumentsDirectory();
      final outputPath = path.join(
        directory.path,
        'timelapse_${timelapseType}_$sessionId.mp4',
      );

      final sessionDir = path.dirname(capturedVideosPath.first);
      final frameRate = _getFrameVideoRates();
      final inputPattern = path.join(sessionDir, 'frame_%05d.jpg');

      final command =
          '-framerate $frameRate -i "$inputPattern" -c:v libx264 -pix_fmt yuv420p -preset ultrafast -y "$outputPath"';

      await FFmpegKit.execute(command).then((session) async {
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          final videoFile = File(outputPath);
          if (await videoFile.exists()) {
            setState(() {
              _generatedVideoPath = outputPath;
              _isProcessing = false;
              _isTimeLapseGenerated = true;
            });

            await _initializeVideoPlayer(outputPath);
            await _saveVideoToGallery(outputPath);

            if (mounted) {
              _showSnackBar("Timelapse saved to gallery!");
            }
          }
        } else {
          setState(() => _isProcessing = false);
          if (mounted) _showSnackBar('Failed to generate video');
        }
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) _showSnackBar('Error: $e');
    }
  }

  Future<void> _initializeVideoPlayer(String videoPath) async {
    try {
      videoPlayerController = VideoPlayerController.file(File(videoPath));
      await videoPlayerController!.initialize();
      await videoPlayerController!.setLooping(true);
      await videoPlayerController!.play();
      setState(() {});
    } catch (e) {
      print('Error initializing video player: $e');
    }
  }

  Future<void> _saveVideoToGallery(String videoPath) async {
    try {
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) return;
      }
      await Gal.putVideo(videoPath, album: 'TimeLapse Videos');
    } catch (e) {
      print("Error saving video to gallery: $e");
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2C2C2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  void dispose() {
    captureTimer?.cancel();
    cameraController?.dispose();
    videoPlayerController?.dispose();
    _recordButtonController.dispose();
    _pulseController.dispose();
    _currentVideoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: Text(
          timelapseType.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () {
              getGalleryImages();
            },
            icon: Icon(Icons.image),
          ),
        ],
      ),
      body: _isCameraInitialized && cameraController != null
          ? Stack(
              children: [
                // Full-screen camera preview
                Positioned.fill(
                  child:
                      _generatedVideoPath != null &&
                          videoPlayerController != null
                      ? _buildVideoPreview()
                      : CameraPreview(cameraController!),
                ),

                // Top gradient overlay
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.6),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // Recording indicators
                if (_isRecording) ...[
                  _buildRecordingIndicator(),
                  if (_latestImagePath != null) _buildLatestImageThumbnail(),
                ],

                // Bottom control panel
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildControlPanel(),
                ),
              ],
            )
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF7C3AED),
                          const Color(0xFF7C3AED).withOpacity(0.6),
                        ],
                      ),
                    ),
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "Initializing Camera...",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildRecordingIndicator() {
    return Positioned(
      top: 100,
      left: 20,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.red.withOpacity(0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withOpacity(0.3 * _pulseAnimation.value),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withOpacity(0.6),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'REC',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildLatestImageThumbnail() {
    return Positioned(
      top: 100,
      right: 20,
      child: Container(
        width: 90,
        height: 90,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.3), width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(_latestImagePath!),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: const Color(0xFF2C2C2E),
                    child: const Icon(
                      Icons.broken_image,
                      color: Colors.white38,
                    ),
                  );
                },
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ClipRRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                      ),
                      child: Text(
                        '$_imageCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPreview() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: videoPlayerController!.value.aspectRatio,
            child: VideoPlayer(videoPlayerController!),
          ),
        ),
        Positioned(
          bottom: 140,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildGlassButton(
                icon: videoPlayerController!.value.isPlaying
                    ? Icons.pause
                    : Icons.play_arrow,
                onPressed: () {
                  setState(() {
                    videoPlayerController!.value.isPlaying
                        ? videoPlayerController!.pause()
                        : videoPlayerController!.play();
                  });
                },
              ),
              const SizedBox(width: 16),
              _buildGlassButton(
                icon: Icons.fiber_manual_record,
                label: 'New',
                onPressed: () {
                  setState(() {
                    _generatedVideoPath = null;
                    videoPlayerController?.dispose();
                    videoPlayerController = null;
                  });
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGlassButton({
    required IconData icon,
    String? label,
    required VoidCallback onPressed,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.15),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: label != null ? 20 : 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: Colors.white, size: 24),
                    if (label != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlPanel() {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.7),
                Colors.black.withOpacity(0.9),
              ],
            ),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
            ),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(context).padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isProcessing)
                _buildProcessingIndicator()
              else ...[
                _buildStatsRow(),
                const SizedBox(height: 28),
                _buildRecordButton(),
                if (capturedVideosPath.isNotEmpty && !_isRecording) ...[
                  const SizedBox(height: 16),
                  _buildMakeVideoButton(),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingIndicator() {
    return Column(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [
                const Color(0xFF7C3AED),
                const Color(0xFF7C3AED).withOpacity(0.6),
              ],
            ),
          ),
          child: const Center(
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 3,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Generating timelapse...',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildStatItem(Icons.photo_camera, '$_imageCount', 'Frames'),
        Container(width: 1, height: 40, color: Colors.white.withOpacity(0.1)),
        _buildStatItem(
          Icons.timer,
          '${_getCaptureTimingsIntervals().inMilliseconds / 1000}s',
          'Interval',
        ),
        Container(width: 1, height: 40, color: Colors.white.withOpacity(0.1)),
        _buildStatItem(Icons.speed, '${_getFrameVideoRates()}', 'FPS'),
      ],
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF7C3AED), size: 20),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildRecordButton() {
    final isDisabled = _generatedVideoPath != null;

    return GestureDetector(
      onTapDown: (_) {
        if (!isDisabled) {
          HapticFeedback.lightImpact();
          _recordButtonController.forward();
        }
      },
      onTapUp: (_) {
        if (!isDisabled) {
          _recordButtonController.reverse();
          if (_isRecording) {
            _stopTimeLapse();
          } else {
            startTimeLapse();
          }
        }
      },
      onTapCancel: () {
        if (!isDisabled) _recordButtonController.reverse();
      },
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: isDisabled ? 1.0 : _scaleAnimation.value,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDisabled
                      ? [
                          Colors.grey.withOpacity(0.3),
                          Colors.grey.withOpacity(0.2),
                        ]
                      : _isRecording
                      ? [
                          Colors.red.withOpacity(0.9),
                          Colors.red.withOpacity(0.7),
                        ]
                      : [const Color(0xFF7C3AED), const Color(0xFF5B21B6)],
                ),
                boxShadow: isDisabled
                    ? []
                    : [
                        BoxShadow(
                          color:
                              (_isRecording
                                      ? Colors.red
                                      : const Color(0xFF7C3AED))
                                  .withOpacity(0.5),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Icon(
                    _isRecording
                        ? Icons.stop_rounded
                        : Icons.fiber_manual_record,
                    key: ValueKey(_isRecording),
                    color: Colors.white,
                    size: _isRecording ? 32 : 40,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMakeVideoButton() {
    return Container(
      width: double.infinity,
      height: 52,
      decoration: _isTimeLapseGenerated
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  const Color.fromARGB(255, 188, 188, 189).withOpacity(0.8),
                  const Color.fromARGB(255, 203, 202, 206).withOpacity(0.8),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color.fromARGB(
                    255,
                    198,
                    195,
                    202,
                  ).withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            )
          : BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF7C3AED).withOpacity(0.8),
                  const Color(0xFF5B21B6).withOpacity(0.8),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7C3AED).withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isTimeLapseGenerated ? null : _generateVideo,
          borderRadius: BorderRadius.circular(16),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.video_library, color: Colors.white, size: 20),
                SizedBox(width: 10),
                _isTimeLapseGenerated
                    ? Text(
                        'Timelapse Generated',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      )
                    : Text(
                        'Generate Timelapse',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
