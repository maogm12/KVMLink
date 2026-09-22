# KVMLink

macOS 菜单栏工具，用一个 USB 设备联动一个外接显示器。

## 功能

- 单选一个 USB 设备和一个外接显示器。
- 设备连接时恢复本机显示；设备断开时停止输出或切换 DDC 输入。
- DDC 输入：HDMI 1 为另一台设备，HDMI 2 为本机。
- 停止联动或退出时恢复本机显示。
- 只操作所选显示器，不操作内置屏幕。
- 不读取键鼠输入，不需要辅助功能、输入监控或屏幕录制权限。
- 界面支持中文和 English，可在底栏切换。

## 构建

```sh
./build.sh
```

要求：Apple Silicon、macOS 13+、Xcode Command Line Tools。

输出：`build/KVMLink.app`

DDC 代码直接编译进主程序，没有独立 helper。第三方许可见 `THIRD-PARTY-NOTICES.md`。
