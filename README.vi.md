# agent-foreman: Claude Code điều phối nhiều AI agent: Antigravity 2, OpenCode, OpenAI Codex, DeepSeek Harness

**Dùng Claude Code (Opus 5.5) làm Tech Lead điều phối các AI coding agent khác trên Windows.** Claude chia việc theo
wave và cho mỗi task một git worktree riêng. Task được giao cho **Google Antigravity 2 (ứng dụng desktop)**,
**Antigravity CLI (`agy`)**, **OpenCode**, **OpenAI Codex CLI** đi kèm **ứng dụng ChatGPT / Codex desktop**,
**DeepSeek Harness**, hoặc bất kỳ CLI lập trình headless nào khác. Với mỗi task, Claude chọn model, agent, skill và
plugin có sẵn trong chính công cụ đó. Sau đó Claude chờ commit HANDOFF, **tự kiểm chứng kết quả với git và tự chạy lại
các bước kiểm tra**, rồi merge hoặc gửi yêu cầu sửa cụ thể.

**Mặc định Claude Code là lead.** Bạn vẫn có thể chủ động chọn harness và model khác làm lead. Ví dụ: **Antigravity 2
ra lệnh cho các worker OpenCode**, hoặc để OpenCode, Antigravity CLI hay Codex điều phối cả nhóm.

[English](README.md)

> Trạng thái: bản sớm (0.4.0). Phần tích hợp Antigravity 2 desktop dùng CLI `agentapi` đi kèm Antigravity 2, cùng một
> số chi tiết nội bộ có thể thay đổi sau mỗi bản cập nhật Antigravity 2. Khi phát hiện thay đổi, adapter sẽ dừng chứ
> không đoán mò. Hãy đọc [docs/SECURITY.md](docs/SECURITY.md) trước.

## Các coding agent (harness) được hỗ trợ

| Harness | Cách điều khiển | Làm worker | Làm lead |
|---|---|---|---|
| **Claude Code** (Opus 5.5 / Sonnet 5.5) | skill của plugin này | — | **mặc định** |
| **Google Antigravity 2** (desktop) | `agentapi` của hub Antigravity 2 (API loopback) | có (`flash_lite`, `flash`, `pro`) | có (skill + script) |
| **Antigravity CLI** (`agy`, model Gemini và Claude) | `agy --print --output-format stream-json` | có | có (skill; MCP qua cấu hình global) |
| **OpenCode** CLI / OpenCode desktop | `opencode run --format json` | có | có (skill + MCP trong `opencode.json`) |
| **OpenAI Codex CLI** / **ứng dụng ChatGPT & Codex desktop** | `codex exec --json` (CLI đi kèm ứng dụng desktop) | có | có (skill; `codex mcp add`) |
| **DeepSeek Harness** (`dsh`) | `dsh headless --json` | có (cần DeepSeek API key) | — |
| CLI lập trình headless bất kỳ | adapter `generic-cli`, cấu hình bằng mảng tham số | có | — |

**Antigravity IDE** (trình soạn thảo cũ) không dùng làm worker được, vì CLI `chat` của nó không chạy task cho agent.

## Yêu cầu

- Windows 10/11, PowerShell 7 (`pwsh`), git, Python 3 (cho MCP server)
- Claude Code (đã thử với Opus 5.5; skill cũng chạy được với Sonnet 5.5)
- Ít nhất một worker trong bảng trên
- Để chạy test: Pester 5 trở lên (`Install-Module Pester -Scope CurrentUser`)

## Cài đặt

```powershell
claude plugin marketplace add AlbedoDz/agent-foreman
claude plugin install agent-foreman@agent-foreman
```

Sau đó, trong Claude Code, mở project của bạn và gõ:

```
/agent-foreman:orchestrator-install ag2,opencode,agy,codex
```

Lệnh này chạy `scripts/install.ps1` (xem trước bằng `-WhatIf`). Trong project của bạn, nó sẽ:
- tạo `.claude/orchestrator/` (script, template, `orchestrator.config.json`, `PLAN.md`);
- thêm **mỗi script đúng một quy tắc allow** vào `.claude/settings.local.json`;
- thêm log, prompt và cấu hình cục bộ vào `.gitignore`;
- cảnh báo nếu URL git remote có nhúng token;
- kiểm tra từng worker.

Với ứng dụng Antigravity 2 desktop, bạn chỉ cần lấy project id một lần. Mở thư mục repo thành một project trong
Antigravity 2, bắt đầu một cuộc hội thoại bất kỳ, rồi chạy:

```powershell
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId
pwsh -NoProfile -File .claude\orchestrator\bin\adapters\ag2.ps1 -FindProjectId -SessionId <id trong danh sách>
```

Ghi giá trị nhận được vào `workers.ag2.projectId`, rồi chạy `/agent-foreman:ag2-check`.

## Sử dụng

Khi bạn nhờ Claude làm việc gồm nhiều phần (ví dụ "chia tính năng này cho các agent"), skill `harness-orchestrator`
sẽ tự chạy. Bạn cũng có thể đi từng bước:

| Lệnh | Tác dụng |
|---|---|
| `/agent-foreman:ag2-check` | kiểm tra mọi worker (Antigravity 2, OpenCode, Antigravity CLI, Codex, DeepSeek Harness) |
| `/agent-foreman:wave 1` | giao mọi task đã sẵn sàng của wave 1 (tối đa 3 task song song) |
| `/agent-foreman:dispatch T1 ag2:flash` | giao một task: tạo worktree, viết prompt, giao việc, bật watcher chạy nền |
| `/agent-foreman:run T1 opencode` | tự chạy trọn vòng: giao việc → chờ → kiểm chứng → tự gửi yêu cầu sửa → kết luận (không tự merge) |
| `/agent-foreman:status` | trạng thái worker, số token đã dùng, đã có HANDOFF hay chưa, theo từng task |
| `/agent-foreman:nudge T1` | đọc đuôi transcript rồi gửi nhắc việc cụ thể |
| `/agent-foreman:review T1` | chạy hợp đồng kiểm chứng và đọc diff, rồi kết luận GO (merge) hoặc FIX |
| `/agent-foreman:delegate-lead ag2:pro "mục tiêu"` | trao vai trò lead cho một harness và model khác trong một mục tiêu |

Với mỗi task, Claude chọn model (`-Model`), agent (`-Agent`) và skill hay lệnh của worker
(`-Prefix "/test-driven-development"`), dựa trên những gì `-Capabilities` báo về harness đó.

## Chọn người điều phối (lead)

- **Mặc định:** Claude Code là lead, thông qua plugin này.
- **Đổi lead cho một mục tiêu:** `/agent-foreman:delegate-lead <harness[:model]> "<mục tiêu>"`. Claude viết lead prompt,
  giao cho harness đó chạy tại thư mục gốc của project, chờ `LEAD_REPORT`, rồi tự kiểm tra lại kết quả.
- **Cho harness khác làm lead lâu dài:** `install.ps1 -Lead opencode,agy,ag2,codex` cài skill `agent-foreman-lead`
  (không phụ thuộc harness) vào `.agents/skills/`. OpenCode, Antigravity CLI và Antigravity 2 đều đọc skill của project
  từ thư mục này. Với OpenCode, installer còn đăng ký **MCP server agent-foreman** vào `opencode.json`. Server nằm ở
  `.claude/orchestrator/bin/mcp/agent_foreman_mcp.py`, chỉ dùng thư viện chuẩn của Python, và có 13 tool: worker,
  khả năng (capabilities), task, giao việc, trạng thái, nhắn tin, huỷ, kiểm chứng, `task_run` và dọn dẹp. Antigravity CLI,
  Antigravity 2 và Codex đọc MCP server từ cấu hình global, nên với chúng installer chỉ in sẵn lệnh, không tự sửa file global.

Quy trình đầy đủ (Plan → Route → Isolate → Dispatch → Watch → Review gate → Merge/Fix → Fallback) nằm trong
[skills/harness-orchestrator/SKILL.md](skills/harness-orchestrator/SKILL.md).

## Cách hoạt động

[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) giải thích:
- cách adapter tìm tiến trình hub của Antigravity 2, rồi truyền địa chỉ loopback và CSRF token cho `agentapi`, chỉ qua biến môi trường của chính tiến trình script;
- vì sao tín hiệu "xong" duy nhất là một commit git có chứa file HANDOFF;
- cách hợp đồng kiểm chứng đưa ra kết luận: lệnh kiểm tra lấy từ plan, test bị khoá, và file bằng chứng.

Mọi script dùng chung một hợp đồng: in đúng một dòng JSON ra stdout; khi lỗi thì exit code khác 0 và in `{ok:false, error, hint}`.
Chi tiết: [hợp đồng adapter](skills/harness-orchestrator/reference/adapter-contract.md). Muốn thêm worker mới, xem
[docs/ADDING-A-HARNESS.md](docs/ADDING-A-HARNESS.md). Khi gặp lỗi, xem [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Những gì đã kiểm chứng

Xem [CHANGELOG.md](CHANGELOG.md). Có hai phần: test Pester (mock tiến trình và API Antigravity 2, dùng repo git tạm
thật) và các lần chạy thật đầu-cuối: worker Antigravity 2 và OpenCode chạy song song, OpenCode làm lead giao việc cho
worker Antigravity 2, và đọc capabilities của mọi harness. Mục nào ghi **chưa kiểm chứng** là chưa chạy với công cụ thật.

## Phát triển

```powershell
Invoke-Pester tests
pwsh -NoProfile -File scripts/secret-scan.ps1          # có thêm -Staged (pre-commit) và -History
claude plugin validate .
```

## Giấy phép

MIT
