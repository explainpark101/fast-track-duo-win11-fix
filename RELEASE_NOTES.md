# English

## Which file should I install?

### Recommended (default)

| Your situation | Install this |
|----------------|--------------|
| **Want working audio without Avid’s buggy kernel driver** (fixes the `+0x1849d` BSoD class by not loading that `.sys`) | **`Fast-Track-Duo-USBAudio.exe`** |

Duo is **USB Audio Class 1.0**. Windows already ships **`usbaudio.sys`** (`wdma_usb.inf`); Avid’s package only outranks it. This installer removes the Avid OEM package and binds Microsoft USB Audio.

**After `Fast-Track-Duo-USBAudio.exe`**

1. UAC / admin approval
2. If prompted or Verify still fails: **reboot once**, run the EXE again if needed
3. Confirm service is `usbaudio` (Device Manager → Driver details, or `Verify-UsbAudio.ps1` from the extract folder / repo)
4. Settings → Sound → Duo → **Spatial sound = Off**; Enhancements → **Disable all**
5. Prefer USB 2.0

### Legacy mitigations (keep Avid `.sys`)

| Your situation | Install this |
|----------------|--------------|
| Official Avid **1.0.4** already installed; you only want the **silence / APO** INF fix without switching stacks | **`1.0.4-patch.exe`** |
| Clean reinstall of community **driver 1.0.5** (modified INF + **original Avid `.sys`**) | **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** |

These two **do not** remove the kernel UAF inside `AvidFastTrackDuo.sys`. Prefer **`Fast-Track-Duo-USBAudio.exe`** unless you need the proprietary stack for a specific ASIO/Pro Tools workflow that fails on class drivers.

### `1.0.4-patch.exe` — patch only (keep 1.0.4)

**Use when** Device Manager already shows official **1.0.4**, and you mainly fight intermittent silence (Spatial toggle “fixes” it) without uninstalling.

**What it does:** leaves `.sys` alone; replaces INF / clears `FX\0` / SysFx; restarts audio.

### `Fast-Track-Duo-Driver_fix.1.0.0.exe` — full reinstall (driver 1.0.5)

**Use when** you want community **1.0.5** INF + Avid `.sys`. Modified INF may need Memory Integrity off / testsigning. If blocked, use official 1.0.4 + **`1.0.4-patch.exe`**, or switch to **`Fast-Track-Duo-USBAudio.exe`**.

### Do not expect any EXE to…

- Repair a bad USB cable / hub / port
- Keep every proprietary mixer/control panel feature of the 2013 Avid package (class driver is PCM-focused)

Docs: `README.md` (English) · `README.ko.md` (한국어)

---

# 한국어

## 어떤 파일을 설치해야 하나요?

### 권장 (기본)

| 상황 | 설치할 파일 |
|------|-------------|
| **Avid 버그 커널 드라이버 없이** 정상 오디오를 쓰고 싶음 (`+0x1849d` BSoD 계열을 `.sys` 자체를 안 써서 회피) | **`Fast-Track-Duo-USBAudio.exe`** |

Duo 는 **USB Audio Class 1.0** 입니다. Windows 에 이미 **`usbaudio.sys`** (`wdma_usb.inf`) 가 있고, Avid 패키지가 순위만 가로챕니다. 이 설치기는 Avid OEM 패키지를 제거하고 Microsoft USB Audio 에 연결합니다.

**`Fast-Track-Duo-USBAudio.exe` 설치 후**

1. UAC / 관리자 승인
2. 안내되거나 Verify 실패 시: **한 번 재부팅** 후 필요하면 EXE 재실행
3. 서비스가 `usbaudio` 인지 확인 (장치 관리자 또는 `Verify-UsbAudio.ps1`)
4. 설정 → 소리 → Duo → **공간 음향 = 끄기**, 향상 효과 **모두 사용 안 함**
5. 가능하면 USB 2.0

### 레거시 완화 (Avid `.sys` 유지)

| 상황 | 설치할 파일 |
|------|-------------|
| 공식 **1.0.4** 유지 + **무음/APO** INF 만 고치고 싶음 | **`1.0.4-patch.exe`** |
| 커뮤니티 **드라이버 1.0.5** (수정 INF + **원본 Avid `.sys`**) 클린 설치 | **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** |

이 둘은 `AvidFastTrackDuo.sys` 안의 커널 UAF 를 **고치지 않습니다**. 클래스 드라이버로 ASIO/Pro Tools 등이 안 되는 특수한 경우가 아니면 **`Fast-Track-Duo-USBAudio.exe`** 를 권장합니다.

### `1.0.4-patch.exe` — 패치만 (1.0.4 유지)

장치 관리자에 공식 **1.0.4** 가 있고, 주로 간헐 무음만 잡을 때. `.sys` 는 그대로 두고 INF/FX 만 정리합니다.

### `Fast-Track-Duo-Driver_fix.1.0.0.exe` — 전체 재설치 (1.0.5)

커뮤니티 1.0.5 INF + Avid `.sys`. 수정 INF 는 메모리 무결성/testsigning 이 필요할 수 있습니다. 막히면 공식 1.0.4 + 패치, 또는 **`Fast-Track-Duo-USBAudio.exe`**.

### 어느 EXE 도 하지 않는 것

- 케이블·허브·포트 불량 해결
- 2013 Avid 전용 믹서/컨트롤 패널의 모든 기능 보장 (클래스 드라이버는 PCM 중심)

문서: `README.md` (English) · `README.ko.md` (한국어)
