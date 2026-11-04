# VCam for iOS

**VCam** is an iOS virtual-camera replacement tweak by **tinysweet**. It lets you choose a photo or video from your media library and use that media in place of the live camera frames delivered through a compatible iOS camera capture pipeline.

VCam is intended for creative camera setups, LARP (live-action role-playing), character or scene role-play, pre-recorded camera scenes, livestream overlays, and other situations where you want a prepared visual source to appear as the camera input.

> VCam replaces frames in a compatible camera pipeline. It does not create a separate physical camera device, and compatibility depends on the app, iOS version, and camera capture path it uses.

## What VCam can do

### Use a photo as the camera source

- Select a photo from the iOS photo library.
- Import it into VCam's local media storage.
- Use the selected image as the replacement camera frame.
- Reposition, rotate, and zoom the image to fit the framing you need.

### Use a video as the camera source

- Select a video from the iOS photo library.
- VCam prepares the imported clip for camera playback, normalizing its orientation and converting it to a camera-friendly stream at up to 1080p / 30 FPS when supported, with 720p / 30 FPS as a fallback.
- The video is muted and automatically starts again from the beginning when it reaches the end, so the clip can repeat during a livestream or role-play session.
- Pause and resume the clip from the floating controls.
- Video frame extraction runs separately from the real-time camera callback. When camera frames stop arriving, VCam pauses video decoding to reduce unnecessary work and resumes when the camera pipeline becomes active again.

### Adjust the camera framing

The floating control panel provides quick controls without reopening the main menu:

- **Move:** shift the replacement image or video up, down, left, or right.
- **Reset position:** return the media to its centered position.
- **Rotate:** rotate the media left or right in 90-degree increments.
- **Zoom:** zoom in or out from 0.1× up to 10×.
- **Video playback:** pause or resume the selected video.

### Tune movement and zoom sensitivity

The Settings section lets you choose how much each control press changes the image. Movement and zoom are configured independently.

**Movement per press:** 0.5%, 1%, 2%, 5%, or 10%.

**Zoom per press:** 0.01×, 0.02×, 0.05×, 0.10×, 0.20×, or 0.50×.

Smaller increments provide finer adjustments; larger increments make repositioning and zooming faster. The selected increments are saved and reused after the menu is closed or the device is restarted.

### Floating controls and touch pass-through

- The floating control can be shown or hidden from the main menu.
- Drag the floating button to place it where it is convenient.
- Tap it to open the compact control panel.
- The panel uses compact icon buttons for movement, rotation, zoom, and video playback.
- Touches outside the visible controls pass through to the app underneath while the menu is closed.
- The floating control starts hidden, so it does not appear until you choose **Show Control**.

### Menu, orientation, and diagnostics

- Press **Volume Up + Volume Down** together to open or close the VCam menu.
- The VCam menu panel follows the device's physical portrait or landscape orientation.
- The overlay is designed not to force the SpringBoard Home Screen to rotate.
- **View Logs** displays runtime information such as camera-service status, media loading, video playback, and whether replacement frames are being rendered.
- **Copy Logs** copies the diagnostic information so it can be shared when troubleshooting.

## Typical workflow

1. Open VCam by pressing **Volume Up + Volume Down** together.
2. Choose **Choose Photo / Video** and select one item from your library.
3. Wait for the import or video optimization process to finish. Importing new media enables Replacement automatically.
4. Confirm that Replacement is enabled and that the selected media is ready.
5. Use **Settings** to choose movement and zoom increments.
6. Select **Show Control** to display the floating button, then drag it to a convenient position.
7. Open the compact control panel to reposition, rotate, zoom, or pause/resume the media while using a compatible camera app.

Only one replacement item is selected at a time. Selecting new media replaces the previously imported item in VCam's media storage.

## Example use cases

- **LARP and role-play:** prepare a character image, scene, or pre-recorded clip to use as the camera visual during a compatible session.
- **Livestream scenes:** repeat a prepared video clip as the camera source while the streaming app's camera capture remains active.
- **Continuous or long-running streams:** use the automatic video loop for a repeating visual source. The loop can reduce the need to restart a clip manually, but it does not guarantee an uninterrupted 24/7 broadcast.
- **Creative demonstrations and testing:** check camera framing, media transforms, and camera-dependent app flows with a consistent visual source.

## Important notes and limitations

- Video playback is muted. VCam does not transmit the video's audio; provide audio separately through your streaming or recording setup.
- Automatic looping repeats the selected clip while the camera playback path is active. It does not keep a livestream online by itself.
- iOS, SpringBoard, mediaserverd, the camera app, network conditions, battery state, heat, or memory pressure can interrupt a long-running session. Do not treat VCam as a guarantee of unattended 24/7 operation.
- VCam works by hooking a camera capture path used by the iOS camera/media services. Apps that use a different or restricted capture path may continue showing the real camera or may not be compatible.
- The actual result can vary across devices, iOS releases, jailbreak environments, and target apps. Test the exact app and streaming setup before relying on it for a live session.
- Keep the device powered and monitor temperature and stream status during extended use.

## Build packages

The included GitHub Actions workflow builds two Debian packages:

- `vcam-rootless.deb` for a rootless jailbreak environment.
- `vcam-roothide.deb` for a RootHide environment.

To build them, push the source to the repository's `main` or `master` branch, open a pull request targeting either branch, or run the workflow manually from the GitHub Actions tab. Download the generated workflow artifact and install the package that matches your jailbreak environment.

The project is configured with an iOS 15.0 deployment target and uses the iOS 16.5 SDK in its Theos Makefile. Actual compatibility still depends on the device, jailbreak, iOS release, and camera capture path.
