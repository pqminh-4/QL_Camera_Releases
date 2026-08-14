# Lịch sử phát hành QL Camera Home

Repository này chỉ ghi nhận các bản phân phối runtime đã được công bố. Mã nguồn ứng dụng, credential và dữ liệu camera không được đưa vào đây.

## [v0.3.1](https://github.com/pqminh-4/QL_Camera_Releases/releases/tag/v0.3.1) — 2026-08-14

### Sửa lỗi

- Khôi phục luồng **Quét thiết bị** với panel, trạng thái đang quét, kết quả ONVIF/USB, lỗi và thao tác quét lại.
- Chuẩn hóa inventory rỗng thành mảng từ host-agent tới API/web và tương thích payload legacy có `null`.
- Ngăn trang **Hệ thống** chuyển thành màn hình đen khi máy chủ không có USB camera.
- Thêm error boundary để một lỗi render không làm mất toàn bộ AppShell.
- Giới hạn thao tác quét/thêm camera cho Owner, Admin và Operator.

### Artifact và xác minh

- Source commit: `ec4d5cc349b099e790f8a18070d523d847b5825e`.
- Release gồm deploy bundle/checksum, host-agent Linux amd64/checksum, manifest image digest, SBOM và Sigstore provenance.
- CI đạt unit/contract/API/web, Chrome E2E, Go race/vet/build, ShellCheck, installer/idempotency, Compose và Docker smoke/Trivy.
- Production Ubuntu 26.04 amd64 đã nâng cấp qua readiness/rollback gate; Docker hiện hữu được giữ nguyên.
- SystemPage ổn định qua chu kỳ inventory và health/WebSocket; scan phát hiện thực tế thiết bị ONVIF và Intel VAAPI.
- Owner, cấu hình, database, secret, vault và media được giữ nguyên sau installer/restart.

### Chưa xác minh trên thiết bị thật

- USB V4L2 và Coral USB chưa được xác minh vì máy chủ không có thiết bị tương ứng.
