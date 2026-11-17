# English

## Which file should I install?

### Quick chooser

| Your situation | Install this |
|----------------|--------------|
| Official Avid **1.0.4** is already installed and working (device shows up), but you have **silence** / want the APO fix without reinstalling | **`1.0.4-patch.exe`** |
| You want a **clean install**, or 1.0.4 is broken/missing, or you prefer the packaged **driver 1.0.5** INF from scratch | **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** |
| Not sure / just want the safest path on a PC that already has 1.0.4 | Prefer **`1.0.4-patch.exe`** first |

### `1.0.4-patch.exe` — patch only (keep 1.0.4)

**Use when**

- Device Manager already shows **Avid Fast Track Duo** with the official **1.0.4** driver
- You mainly fight **intermittent total silence** (Spatial Sound toggle “fixes” it)
- You do **not** want to uninstall/reinstall the whole driver stack

**What it does**

- Leaves `AvidFastTrackDuo.sys` alone
- Replaces published / DriverStore INF with the no-Home-Theater-FX variant
- Clears DeviceClasses `FX\0` / `MSFX` and disables SysFx on Duo endpoints
- Restarts audio services / toggles the device

**After install**

1. Settings → System → Sound → Duo → **Spatial sound = Off**
2. Sound Control Panel → Duo → Enhancements → **Disable all**
3. Prefer a USB 2.0 port

### `Fast-Track-Duo-Driver_fix.1.0.0.exe` — full reinstall (driver 1.0.5)

**Use when**

- Duo is **not** installed, or install is corrupted
- You want to **remove** the stock 1.0.4 package and install the community **1.0.5** INF package in one step
- Fresh Windows / new PC setup

**What it does**

- Uninstalls existing Duo PnP devices and related driver packages
- Installs community **driver 1.0.5** (modified INF without `mssysfx` / `FX\0` + original Avid `.sys`)
- Runs the same FX cleanup as the patch

**Important**

- The INF is intentionally modified, so there is **no matching CAT**. Windows may block install until **Memory Integrity** is off and/or **testsigning** is enabled.
- If the full installer is blocked, install official **1.0.4** from Avid, then run **`1.0.4-patch.exe`** instead.

**After install**

Same Spatial / Enhancements steps as above.

### Do not expect either EXE to…

- Fix the kernel bug inside `.sys` at `+0x1849d` (needs a WHCP-signed rebuild)
- Replace a broken USB cable / hub / port issue

Docs: `README.md` (English) · `README.ko.md` (한국어)

---

# 한국어

## 어떤 파일을 설치해야 하나요?

### 빠른 선택

| 상황 | 설치할 파일 |
|------|-------------|
| 공식 **1.0.4** 가 이미 설치되어 장치는 보이는데, **무음** 등이 있고 재설치는 하기 싫음 | **`1.0.4-patch.exe`** |
| **클린 설치**가 필요하거나, 1.0.4 가 깨졌/없음, 처음부터 **드라이버 1.0.5** 패키지를 올리고 싶음 | **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** |
| 잘 모르겠고, PC에 이미 1.0.4 가 있음 | 먼저 **`1.0.4-patch.exe`** |

### `1.0.4-patch.exe` — 패치만 (1.0.4 유지)

**이럴 때**

- 장치 관리자에 **Avid Fast Track Duo** / 공식 **1.0.4** 가 이미 있음
- 주로 **간헐적 완전 무음** (공간 음향 토글하면 다시 들림)
- 드라이버 전체를 지우고 다시 깔기 싫음

**하는 일**

- `.sys` 는 그대로 둠
- DriverStore / 게시 INF 를 Home Theater FX 제거본으로 교체
- DeviceClasses `FX\0` / `MSFX` 정리, SysFx 비활성
- 오디오 서비스·장치 재시작

**설치 후**

1. 설정 → 시스템 → 소리 → Duo → **공간 음향 = 끄기**
2. 제어판 소리 → Duo → 향상 효과 → **모두 사용 안 함**
3. 가능하면 USB 2.0 포트

### `Fast-Track-Duo-Driver_fix.1.0.0.exe` — 전체 재설치 (드라이버 1.0.5)

**이럴 때**

- Duo 가 **미설치**이거나 설치가 망가짐
- 공식 1.0.4 패키지를 **제거하고** 커뮤니티 **1.0.5** INF 로 한 번에 올리고 싶음
- 새 PC / 초기 세팅

**하는 일**

- 기존 Duo 장치·드라이버 패키지 제거
- 커뮤니티 **드라이버 1.0.5** 설치 (FX 제거 INF + Avid 원본 `.sys`)
- 패치와 동일한 FX 정리

**주의**

- INF 가 수정되어 **일치하는 CAT 이 없음**. **메모리 무결성** 끄기 및/또는 **testsigning** 이 필요할 수 있음.
- 풀 설치가 막히면 Avid 공식 **1.0.4** 설치 후 **`1.0.4-patch.exe`** 를 사용.

**설치 후**

위와 동일하게 공간 음향 Off / 향상 효과 Off.

### 어느 EXE 도 하지 않는 것

- `.sys` 내부 `+0x1849d` 커널 버그 자체 수정 (WHCP 서명 재빌드 필요)
- 케이블·허브·포트 불량 해결

문서: `README.md` (English) · `README.ko.md` (한국어)
