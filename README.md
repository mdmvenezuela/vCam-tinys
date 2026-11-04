# VCam iOS 0.1.32

Virtual camera replacement for iOS with photo and video support, image positioning and transform controls, and a floating control panel.

By tinysweet.

Zoom range: 0.1× to 10×. The Settings menu lets you choose the zoom increment (0.01×–0.50×) and movement increment (0.5%–10%) for each button press. Both preferences are saved between launches.


The SpringBoard overlay stays non-key while idle and restores the previous key window after closing the menu, avoiding interference with normal device auto-rotation.


### Orientation isolation (0.1.32)
- The SpringBoard overlay controller does not autorotate and advertises portrait-only support so it cannot introduce landscape rotation to the iPhone Home Screen.
