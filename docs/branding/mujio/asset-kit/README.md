# MUJIO 跨平台品牌素材

本目录收纳可复用的 MUJIO 玻璃字标应用图标、启动/横幅展示图，以及当前 tvOS 分层图标素材。图标源图均为完整方形画布，未预先做圆角；iOS、Android 和 macOS 可按各自平台规范套用外形遮罩。

## 图标

- `icons/source/MUJIO-dark-master.png` — 深色背景母图，1254 × 1254。
- `icons/source/MUJIO-light-master.png` — 浅色背景母图，1254 × 1254。
- `icons/MUJIO-{dark,light}-{1024,512,256,128,64}.png` — 常用方形导出尺寸。
- `android/MUJIO-PlayStore-{dark,light}-512.png` — Android 商店 512 × 512 图标。
- `android/launcher/` — mdpi、hdpi、xhdpi、xxhdpi、xxxhdpi 的 48、72、96、144、192 px launcher PNG，分别提供深色/浅色底。
- `ios/` — iOS 1024 × 1024 深色/浅色 App Store 源图。
- `macos/MUJIO-{dark,light}.icns` — macOS 图标容器；对应 `.iconset/` 子目录保留构建 `.icns` 用的 PNG 尺寸源图。

## 横向展示图与电视端图层

- `banners/MUJIO-launch-dark-1672x941.png` — 深色启动/品牌展示图。
- `banners/MUJIO-banner-light-1942x809.png` — 浅色横幅/品牌展示图。
- `banners/QuarkTheater-TopShelf-1920x720.png`、`QuarkTheater-TopShelf-Wide-2320x720.png` — tvOS Top Shelf 横幅源图。
- `tvos-layered/` — tvOS 桌面图标的 Back、Middle、Front 三层 PNG（400 × 240）。

深浅两种应用图标都使用同一玻璃字标。浅色版按浅色背景重新渲染，深色版沿用已定稿的深色概念图。各平台的圆角、圆形或其他外形应由平台在方形源图上处理，避免素材边缘被重复裁切。
