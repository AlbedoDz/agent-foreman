# ag2-orchestrator

**Dùng Claude Code làm Tech Lead điều phối các coding agent khác trên Windows.** Claude chia việc theo wave, cho mỗi
task một git worktree riêng, rồi giao task cho **Antigravity 2** (bản desktop), **OpenCode** hoặc bất kỳ harness nào có CLI headless.
Sau đó Claude chờ commit HANDOFF, **đối chiếu báo cáo với git và tự chạy lại test**, rồi mới merge hoặc gửi yêu cầu sửa.

[English](README.md)

> Trạng thái: bản sớm (0.1.0). Phần AG2 dùng CLI `agentapi` đi kèm Antigravity 2 cùng vài chi tiết nội bộ có thể đổi
> sau mỗi bản cập nhật. Khi phát hiện thay đổi, adapter sẽ dừng chứ không chạy mò. Hãy đọc [docs/SECURITY.md](docs/SECURITY.md) trước.

## Yêu cầu

- Windows 10/11, PowerShell 7 (`pwsh`), git
- Claude Code (đã thử với Opus 5.5; skill viết để chạy được cả với Sonnet 5.5)
- Ít nhất một worker: Antigravity 2 desktop, và/hoặc OpenCode đã cấu hình provider
- Để chạy test: Pester 5 trở lên (`Install-Module Pester -Scope CurrentUser`)

## Cài đặt

```powershell
claude plugin marketplace add <owner>/ag2-orchestrator
claude plugin install ag2-orchestrator@ag2-orchestrator
```

Sau đó, trong Claude Code, mở project của bạn và gõ:

```
/ag2-orchestrator:orchestrator-install ag2,opencode
```

Lệnh này chạy `scripts/install.ps1` (có xem trước bằng `-WhatIf`). Nó làm những việc sau:
- tạo `.claude/orchestrator/` gồm script, template, `orchestrator.config.json` và `PLAN.md`;
- thêm vào `.claude/settings.local.json` **mỗi script đúng một quy tắc allow**;
- thêm log, prompt và config cục bộ vào `.gitignore`;
- cảnh báo nếu URL git remote có nhúng token;
- chạy kiểm tra từng worker.

Với AG2, chỉ cần lấy project id một lần: mở thư mục repo thành một project trong Antigravity 2, bắt đầu một cuộc hội thoại bất kỳ, rồi chạy:

```powershell
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId -SessionId <id trong danh sách>
```

Ghi giá trị nhận được vào `workers.ag2.projectId`, rồi chạy `/ag2-orchestrator:ag2-check`.

## Sử dụng

Khi bạn nhờ Claude làm việc gồm nhiều phần (ví dụ "chia tính năng này cho các agent"), skill `harness-orchestrator` sẽ tự chạy. Bạn cũng có thể đi từng bước:

| Lệnh | Tác dụng |
|---|---|
| `/ag2-orchestrator:ag2-check` | kiểm tra các worker |
| `/ag2-orchestrator:wave 1` | giao mọi task đã sẵn sàng của wave 1 (tối đa 3 task song song) |
| `/ag2-orchestrator:dispatch T1 ag2:flash` | giao một task: tạo worktree, viết prompt, giao việc, bật watcher chạy nền |
| `/ag2-orchestrator:status` | trạng thái worker và cho biết đã có HANDOFF hay chưa, theo từng task |
| `/ag2-orchestrator:nudge T1` | đọc đuôi transcript rồi gửi nhắc việc cụ thể |
| `/ag2-orchestrator:review T1` | đối chiếu HANDOFF với git, đọc diff, chạy lại test, rồi kết luận GO (merge) hoặc FIX |

Quy trình đầy đủ (Plan → Route → Isolate → Dispatch → Watch → Review gate → Merge/Fix → Fallback) nằm trong
[skills/harness-orchestrator/SKILL.md](skills/harness-orchestrator/SKILL.md).

## Cách hoạt động

[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) giải thích ba điều:
- Script tìm tiến trình hub của AG2 và lấy địa chỉ loopback cùng CSRF token. Hai giá trị này chỉ được truyền cho `agentapi` qua biến môi trường của chính tiến trình script.
- Tín hiệu "xong" duy nhất là một commit git có chứa file HANDOFF.
- Trạng thái running/idle của AG2 chỉ là suy luận từ thời gian sửa file transcript, không phải dữ liệu AG2 trả về.

Mọi script dùng chung một hợp đồng: in đúng một dòng JSON ra stdout; khi lỗi thì exit code khác 0 và in `{ok:false, error, hint}`.
Chi tiết: [hợp đồng adapter](skills/harness-orchestrator/reference/adapter-contract.md). Thêm worker mới:
[docs/ADDING-A-HARNESS.md](docs/ADDING-A-HARNESS.md). Khi gặp lỗi: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Những gì đã kiểm chứng

Xem [CHANGELOG.md](CHANGELOG.md). Có hai phần: test Pester (mock AG2 và tiến trình, dùng repo git tạm thật) và một smoke test
đầu-cuối chạy thật. Mục nào ghi **chưa kiểm chứng** là chưa chạy với công cụ thật.

## Phát triển

```powershell
Invoke-Pester tests
pwsh -NoProfile -File scripts/secret-scan.ps1          # có thêm -Staged (pre-commit) và -History
claude plugin validate .
```

## Giấy phép

MIT
