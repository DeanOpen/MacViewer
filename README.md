<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Biểu tượng MacViewer">

# MacViewer

**Ứng dụng UltraViewer gốc cho macOS: điều khiển máy tính khác từ máy Mac, hoặc chia sẻ máy Mac của bạn.**

**Tiếng Việt** · [English](README.en.md)

[![CI](https://github.com/DeanOpen/MacViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/DeanOpen/MacViewer/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DeanOpen/MacViewer?sort=semver)](https://github.com/DeanOpen/MacViewer/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

<img src="docs/images/main-window-vi.png" width="820" alt="Cửa sổ chính của MacViewer">

</div>

---

MacViewer kết nối đến các máy tính khác đang chạy **UltraViewer** (hoặc
MacViewer) và nhận các kết nối đến sau khi bạn chấp thuận. Ứng dụng được viết
bằng SwiftUI và AppKit, dựa trên một bộ xử lý giao thức Swift/C. Ứng dụng không
dùng Wine và không chạy bất kỳ mã thực thi Windows nào.

> [!IMPORTANT]
> MacViewer là một bản triển khai độc lập do cộng đồng phát triển. Đây **không**
> phải sản phẩm chính thức của UltraViewer và không liên kết hay được bảo trợ bởi
> nhà phát triển UltraViewer. Chỉ kết nối đến những máy tính bạn được phép truy cập.

## Tính năng

### Kết nối (điều khiển máy tính khác)

- Kết nối bằng **ID và mật khẩu** đối tác hiển thị trong UltraViewer trên máy kia
- Tra cứu và đăng nhập đối tác được mã hóa, máy chủ chuyển tiếp TLS có kiểm tra
  chứng chỉ, và **kết nối trực tiếp trong mạng LAN**, tự chuyển sang máy chủ
  chuyển tiếp khi cần
- Giải mã màn hình nhanh (từ điển Zstandard, RGB555/JPEG, cuộn/sao chép vùng,
  bộ nhớ đệm ô)
- Điều khiển bàn phím và chuột do bạn tự bật:
  <kbd>⌘</kbd> → Win, <kbd>⌥</kbd> → Alt, <kbd>⌃</kbd> → Ctrl,
  hỗ trợ cuộn bằng bàn di chuột và con lăn
- Thanh công cụ chọn màn hình, tỉ lệ hiển thị, chất lượng, hình nền, con trỏ từ
  xa và **âm thanh của máy từ xa**
- Chụp màn hình có chọn vùng và chú thích, cùng **quay video**
- Khung **trò chuyện** nổi và **chia sẻ bộ nhớ tạm** hai chiều (tùy chọn bật)
- Lưu mật khẩu trong **Chuỗi khóa macOS** (tùy chọn)

### Chia sẻ (chia sẻ máy Mac này)

- Chia sẻ màn hình máy Mac với người dùng UltraViewer khác, sau khi bạn chấp
  thuận từng kết nối trên máy Mac
- Hướng dẫn tích hợp để cấp quyền **Ghi màn hình** và **Trợ năng**
- Bạn chấp thuận riêng quyền xem và quyền điều khiển. Bạn có thể kết thúc phiên
  hoặc tạm dừng truy cập từ xa bất cứ lúc nào.

### Chung

- Giao diện tiếng Việt và tiếng Anh, hoặc theo ngôn ngữ hệ thống
- Bản dựng Universal (Apple silicon + Intel), yêu cầu macOS 14 Sonoma trở lên

### Chưa hỗ trợ

Truyền tệp, micro/trò chuyện thoại, âm thanh khi chia sẻ máy Mac, chia sẻ nhiều
màn hình Mac, và truy cập máy Mac không cần người trực. Các phiên bản UltraViewer
Windows cũ, bàn phím không phải kiểu Mỹ/bộ gõ (IME) và chế độ màn hình 8 bit
chưa được kiểm chứng.

## Cài đặt

1. Tải tệp `MacViewer-<phiên bản>.dmg` (hoặc `.zip`) mới nhất tại
   [**Releases**](https://github.com/DeanOpen/MacViewer/releases/latest).
2. Mở tệp DMG và kéo **MacViewer** vào thư mục **Applications**.
3. Nếu bản phát hành chưa được Apple công chứng (notarize), macOS sẽ chặn lần mở
   đầu tiên. Nhấp chuột phải vào ứng dụng, chọn **Open** rồi xác nhận. Hoặc chạy:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MacViewer.app
   ```

## Cách dùng

**Kết nối đến máy khác:** Nhập **ID** và **mật khẩu** của đối tác hiển thị trong
UltraViewer, rồi bấm **Kết nối đến máy khác**. Để gửi thao tác bàn phím và
chuột, bật **Điều khiển** trên thanh công cụ của phiên.

**Chia sẻ máy Mac này:** Bấm **Bắt đầu chia sẻ máy Mac** và làm theo hướng dẫn
cấp quyền:

| Quyền | Dùng để |
| --- | --- |
| Ghi màn hình | Cho phép máy kia xem màn hình của bạn |
| Trợ năng | Cho phép máy kia điều khiển bàn phím và chuột |

Nhập ID và mật khẩu của máy Mac trên máy kia, rồi chấp thuận yêu cầu trên máy
Mac. Nếu macOS yêu cầu, hãy mở lại MacViewer sau khi thay đổi quyền Ghi màn hình.

## Tự build từ mã nguồn

Yêu cầu: macOS 14+, Xcode 16+ / Swift 6+.

```sh
git clone https://github.com/DeanOpen/MacViewer.git
cd MacViewer

swift test                       # chạy bộ kiểm thử
scripts/package_app.sh release   # build dist/MacViewer.app
open dist/MacViewer.app
```

## Cấu trúc dự án

```
Sources/
  MacViewer/              Ứng dụng SwiftUI/AppKit (giao diện, chụp màn hình, nhập liệu, chia sẻ)
  UltraViewerProtocol/    Bộ xử lý giao thức: mã hóa, chuyển tiếp, giải mã màn hình, âm thanh
ThirdParty/
  zstd/                   Zstandard 1.5.7 (BSD / GPLv2)
  g722/                   Bộ giải mã WebRTC G.722
Tests/                    Kiểm thử giao thức và ứng dụng
scripts/                  Đóng gói ứng dụng và tạo biểu tượng
```

## Đóng góp

Rất hoan nghênh issue và pull request. Trước khi mở PR, vui lòng:

1. Chạy `swift test` và đảm bảo tất cả đều qua.
2. Thêm chuỗi hiển thị mới vào cả `en.lproj` và `vi.lproj`.
3. Không bao giờ commit thông tin đăng nhập, ID đối tác, token phiên hay tệp
   nhị phân của UltraViewer.

## Quyền riêng tư

MacViewer không thu thập dữ liệu sử dụng. Mật khẩu chỉ được lưu khi bạn chọn ghi
nhớ, và chỉ lưu trong Chuỗi khóa macOS. Mật khẩu không bao giờ được ghi vào lịch
sử đối tác, UserDefaults hay hồ sơ đăng ký.

## Giấy phép

MacViewer được phát hành theo [Giấy phép MIT](LICENSE).

Các thành phần bên thứ ba đi kèm giữ nguyên giấy phép riêng. Xem
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Tệp từ điển màn hình `8bit.dat`
là dữ liệu do UltraViewer cung cấp và **không** thuộc phạm vi giấy phép MIT.

UltraViewer là thương hiệu của chủ sở hữu tương ứng và chỉ được nhắc đến ở đây
để mô tả khả năng tương thích.
