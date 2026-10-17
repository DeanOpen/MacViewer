<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Biểu tượng MacViewer">

# MacViewer

**Dùng UltraViewer ngay trên máy Mac: điều khiển máy khác hoặc cho người khác truy cập máy Mac của bạn.**

**Tiếng Việt** · [English](README.en.md)

### [Tải về MacViewer cho macOS](https://github.com/DeanOpen/MacViewer/releases/latest)

Bản mới nhất, macOS 14 trở lên

[![CI](https://github.com/DeanOpen/MacViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/DeanOpen/MacViewer/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DeanOpen/MacViewer?sort=semver)](https://github.com/DeanOpen/MacViewer/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

<img src="docs/images/main-window-vi.png" width="820" alt="Giao diện chính của MacViewer">

</div>

---

[UltraViewer](https://ultraviewer.net/vi/) chỉ có bản cho Windows. MacViewer là ứng dụng macOS thuần, giúp
bạn kết nối tới máy đang chạy UltraViewer (hoặc MacViewer), và cho phép người
khác điều khiển máy Mac của bạn khi bạn đồng ý. Ứng dụng viết bằng
SwiftUI/AppKit, không cần Wine và không chạy bất kỳ file `.exe` nào của Windows.

> [!IMPORTANT]
> MacViewer là dự án cá nhân, mã nguồn mở, **không phải** sản phẩm chính thức
> của UltraViewer và không liên quan gì đến đội ngũ phát triển UltraViewer.
> Chỉ kết nối tới những máy mà bạn được phép truy cập.

## Tính năng

### Kết nối tới máy khác

- Nhập **ID và mật khẩu** hiện trên UltraViewer của máy kia là kết nối được
- Kết nối được mã hóa, đi qua máy chủ trung gian có TLS; nếu hai máy cùng mạng
  LAN thì tự kết nối trực tiếp cho nhanh
- Hiển thị màn hình mượt, hỗ trợ cả màn hình 4K
- Điều khiển chuột, bàn phím (chỉ khi bạn bật **Điều khiển**). Phím được chuyển
  đổi sẵn: <kbd>⌘</kbd> → Win, <kbd>⌥</kbd> → Alt, <kbd>⌃</kbd> → Ctrl. Cuộn
  bằng trackpad hay chuột đều được
- Thanh công cụ: chọn màn hình, thu phóng, chất lượng hình, ẩn/hiện hình nền,
  con trỏ chuột và **nghe âm thanh từ máy kia**
- Chụp màn hình (chọn vùng, ghi chú lên ảnh) và **quay video**
- **Chat** với người bên kia và đồng bộ **clipboard** hai chiều (tùy chọn)
- Có thể lưu mật khẩu vào **Keychain** của macOS cho lần sau

### Cho người khác truy cập máy Mac

- Người khác chỉ xem hoặc điều khiển được sau khi bạn bấm đồng ý trên máy Mac
- Có hướng dẫn từng bước để bật quyền **Ghi màn hình** và **Trợ năng**
- Quyền xem và quyền điều khiển được duyệt riêng. Bạn có thể ngắt kết nối hoặc
  tạm khóa truy cập bất cứ lúc nào

### Khác

- Giao diện tiếng Việt và tiếng Anh, hoặc tự theo ngôn ngữ của máy
- Chạy trên cả chip Apple (M1, M2…) và Intel, yêu cầu macOS 14 Sonoma trở lên

### Chưa hỗ trợ

Gửi file, nói chuyện qua micro, phát âm thanh khi chia sẻ máy Mac, chia sẻ
nhiều màn hình Mac cùng lúc và truy cập không cần người ngồi máy. Chưa thử
nghiệm với các bản UltraViewer cũ, bàn phím không phải kiểu US, bộ gõ tiếng Việt
khi điều khiển, và chế độ màu 8-bit.

## Cài đặt

Cài bằng [Homebrew](https://brew.sh):

```sh
brew install --cask deanopen/tap/macviewer
```

Hoặc cài thủ công:

1. Vào trang [**Tải về**](https://github.com/DeanOpen/MacViewer/releases/latest) và tải file `MacViewer-<phiên bản>.dmg`.
2. Mở file DMG, kéo **MacViewer** thả vào thư mục **Applications**.
3. Mở MacViewer từ Launchpad hoặc thư mục Applications.

Khi có bản mới, MacViewer hiện nút **Cập nhật lên …** trên thanh tiêu đề. Bấm
vào, xem có gì mới, rồi bấm **Cập nhật và khởi động lại**: ứng dụng tự tải về,
kiểm tra chữ ký, cài đặt và mở lại. Bạn cũng có thể chọn **MacViewer → Kiểm tra
bản cập nhật…** trên thanh menu.

Nếu macOS báo không mở được ứng dụng, hãy nhấp chuột phải vào MacViewer, chọn
**Open** rồi bấm **Open** lần nữa. Hoặc chạy lệnh:

```sh
xattr -dr com.apple.quarantine /Applications/MacViewer.app
```

## Hướng dẫn sử dụng

**Điều khiển máy khác:** Nhập **ID** và **mật khẩu** đang hiện trên UltraViewer
của máy kia, rồi bấm **Kết nối đến máy khác**. Muốn dùng chuột và bàn phím thì
bật **Điều khiển** trên thanh công cụ.

**Cho người khác vào máy Mac:** Bấm **Bắt đầu chia sẻ máy Mac** và làm theo
hướng dẫn để bật quyền:

| Quyền | Để làm gì |
| --- | --- |
| Ghi màn hình | Người kia nhìn thấy màn hình của bạn |
| Trợ năng | Người kia điều khiển được chuột và bàn phím |

Gửi ID và mật khẩu của máy Mac cho người kia, rồi bấm đồng ý khi có yêu cầu
kết nối. Nếu macOS yêu cầu, hãy tắt và mở lại MacViewer sau khi bật quyền Ghi
màn hình.

## Build từ mã nguồn

Cần macOS 14 trở lên và Xcode 16 / Swift 6 trở lên.

```sh
git clone https://github.com/DeanOpen/MacViewer.git
cd MacViewer

swift test                       # chạy test
scripts/package_app.sh release   # build ra dist/MacViewer.app
open dist/MacViewer.app
```

## Cấu trúc thư mục

```
Sources/
  MacViewer/              Ứng dụng (giao diện, chụp màn hình, điều khiển, chia sẻ)
  UltraViewerProtocol/    Phần giao thức: mã hóa, kết nối, giải mã hình ảnh, âm thanh
ThirdParty/
  zstd/                   Thư viện nén Zstandard 1.5.7 (BSD / GPLv2)
  g722/                   Bộ giải mã âm thanh G.722 của WebRTC
Tests/                    Unit test
scripts/                  Script đóng gói app và tạo file DMG
```

## Đóng góp

Mọi issue và pull request đều được chào đón. Trước khi gửi PR, bạn vui lòng:

1. Chạy `swift test` và đảm bảo không có test nào lỗi.
2. Nếu thêm chữ mới trên giao diện, thêm vào cả `en.lproj` và `vi.lproj`.
3. Không commit mật khẩu, ID đối tác, token hay file cài đặt của UltraViewer.

## Quyền riêng tư

MacViewer không thu thập bất kỳ dữ liệu nào. Khi kiểm tra bản cập nhật, ứng dụng
chỉ đọc thông tin phiên bản công khai trên GitHub (có thể tắt trong Cài đặt). Mật khẩu chỉ được lưu khi bạn chọn
ghi nhớ, và chỉ lưu trong Keychain của macOS. Lịch sử kết nối chỉ lưu ID, không
bao giờ lưu mật khẩu.

## Giấy phép

MacViewer phát hành theo [giấy phép MIT](LICENSE).

Các thư viện bên thứ ba vẫn giữ giấy phép riêng của chúng, xem
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). File `8bit.dat` là dữ liệu
lấy từ UltraViewer và **không** thuộc giấy phép MIT.

UltraViewer là thương hiệu của chủ sở hữu tương ứng, chỉ được nhắc đến ở đây để
nói rõ khả năng tương thích.
