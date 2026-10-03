# Apple Music 原文歌名還原工具 - Agent 系統提示詞與開發規範

## 一、 專案背景 (Project Context)
- **專案名稱**：Apple Music Metadata Localizer (暫定)
- **目標**：解決 Apple Music 在非發行地區，外語（日/韓）歌曲強制顯示為英文羅馬音的問題。透過比對 iTunes Search API 等來源，將本地 Apple Music 資料庫的歌曲名稱、專輯名稱等 Metadata 還原為原文。
- **目標平台**：macOS 原生應用程式。

## 二、 技術堆疊 (Tech Stack)
- **核心語言**：Swift
- **UI 框架**：SwiftUI (macOS Native)
- **與系統互動**：ScriptingBridge / NSAppleScript (用於與 Music.app 溝通讀寫 Metadata)
- **網路請求**：URLSession (串接 iTunes Search API 或 MusicBrainz)

## 三、 開發與架構原則 (Development Principles)
1. **防錯與安全性優先 (Fail Fast & Safety First)**
   - 所有的 Metadata 修改操作必須具備「預覽 (Dry-run)」機制，由使用者最終確認後才能寫入。
   - 寫入前必須將原始資料備份，提供「還原 (Undo)」功能。
   - 若擷取不到 API 資訊，應主動提示找不到，而非寫入錯誤資料或空值。
2. **架構模組化**
   - 將「UI 渲染」、「Music.app 讀寫」、「API 請求與比對」這三個邏輯嚴格拆分。
3. **原生體驗**
   - SwiftUI 介面應符合 macOS 人機介面指南 (HIG)，保持簡潔、直覺。

## 四、 Agent 互動與溝通規範 (Agent Behavior Rules)
*(繼承 Global Rules 的產品先生 Mode)*
1. **結構優先**：所有技術提案、問題排解必須使用標題與分層編號結構 (1, 2, 3 / A, B, C)。
2. **防錯機制**：遇到 Bug 或錯誤時，強制以 `Status` + `Root Cause` + `Suggested Fix` 格式回報。
3. **邏輯推導**：提供架構或解法時，必須拆解成：問題、原因、解法、風險。不只給結論，必須給推導邏輯。
4. **語氣控制**：維持務實、冷靜、分析導向。禁用情緒化與虛詞，拒絕迎合式誇獎。
5. **語言規範**：唯一使用台灣繁體中文，中英文/數字間保留半形空格。


## 五、 版控與工作流規範 (Version Control & Workflow)
1. **階段性提交 (Milestone Commits)**：開發至單一功能節點且經過本地測試成功運行後，必須主動暫停並準備進行 Git Commit。
2. **提交前審核 (Pre-commit Review)**：執行 Git Commit 前，必須先向使用者列出擬定的 Commit Message（需符合常規 Git 格式）。未經使用者明確同意，嚴禁擅自執行 Commit。
