# QL Camera Home Releases

Repository này chỉ phân phối installer và artifact production của QL Camera Home. Mã nguồn ứng dụng được quản lý trong repository private.

## Cài đặt

QL Camera Home hỗ trợ Ubuntu Server 24.04/26.04 LTS amd64. Chạy installer bằng quyền root:

```bash
curl -fsSL https://raw.githubusercontent.com/pqminh-4/QL_Camera_Releases/main/install.sh | sudo bash
```

Installer xác minh checksum của deploy bundle và host-agent, sau đó khởi động API/web bằng image GHCR public đã ghim SHA-256 digest trong `release-manifest.json`.

## Artifact

Mỗi release cung cấp deploy bundle, checksum, host-agent Linux amd64, manifest image digest, SBOM và build provenance. Repository này không chứa TypeScript/Go source, credential, dữ liệu camera hoặc bản ghi.

Phần mềm là proprietary và chỉ dành cho người dùng được chủ sở hữu cho phép theo thỏa thuận riêng. Xem `LICENSE` trước khi sử dụng.
