# Steam Library Risk Scanner

A PowerShell script that scans your Steam library and evaluates potential **security and privacy risks** associated with installed games.  
The script assigns each title a **risk score** based on factors like developer/publisher origin, anti-cheat type, DRM presence, and other red flags, and generates an **HTML report** for easy review.

---

## Features

- 🔎 **Steam Library Scanning** – Detects installed games automatically.  
- 📊 **Risk Scoring** – Assigns scores for findings such as:
  - Publisher/Developer country of origin  
  - Kernel-level or non-kernel anti-cheat usage  
  - DRM and always-online requirements  
  - Keywords in game/company metadata  
- 📝 **HTML Report** – Clean, interactive report with:
  - Game metadata (title, publisher, developer)  
  - Risk score breakdown with tooltips (why each point was added)  
  - Visual indicators for higher-risk titles  
- ⚙️ **Configurable** – Edit scoring weights (e.g., +5 for Chinese origin, +4 for kernel AC)  
- 📂 **JSON Database** – Saves results in `steam_scan.json` for future reference.

---

## Requirements

- Windows 10/11  
- PowerShell 5.1 or PowerShell 7+  

---

## Usage

1. Clone this repository or download the script:  
   ```powershell
   git clone https://github.com/elblayko/SteamLibrary-RiskScanner.git
   cd SteamLibrary-RiskScanner
   ```

2. Run the script in PowerShell:  
   ```powershell
   ./SteamLibrary-RiskScanner.ps1
   or
   powershell -ExecutionPolicy Bypass -File "./SteamLibrary-RiskScanner.ps1"
   ```

3. After execution:
   - Results are stored in `steam_scan.json`  
   - An HTML report is generated (`steam_scan_report.html`)  

---

## Example Report

- Risk Score: **7**  
- Factors contributing to score:  
  - Publisher in China (+5)  
  - Kernel-level Anti-Cheat (+4)  
  - DRM keyword match (+1)  

Tooltips in the report explain **why** each finding increased the score.

---

## Disclaimer

This tool provides **informational risk scoring only**.  
It does **not** definitively determine if a game is safe or unsafe. Always do your own research before making decisions about installation or play.

<img width="3073" height="1717" alt="Screenshot 2025-08-29 at 22-00-43 Steam Library Risk Report" src="https://github.com/user-attachments/assets/9980ab9d-d060-4f5c-b108-86a66a188e33" />
