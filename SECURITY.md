# Bảo mật bản phát hành QL Camera Home

Không đăng camera URL, API token, mật khẩu, TOTP secret, webhook URL hoặc log chưa loại bỏ dữ liệu nhạy cảm vào issue công khai.

Khi báo cáo lỗ hổng, hãy dùng kênh liên hệ riêng do chủ sở hữu cung cấp và gửi kèm phiên bản release, hệ điều hành cùng bước tái hiện đã loại bỏ PII. Không đính kèm `.env`, thư mục `secrets`, database hoặc bản ghi camera.

Installer chính thức chỉ tải artifact từ `pqminh-4/QL_Camera_Releases`, xác minh SHA-256 và chỉ chấp nhận image `ghcr.io` được ghim bằng digest.
