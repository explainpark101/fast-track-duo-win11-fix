<img src="assets/icon.svg" width="64" height="64" alt="">

# Fast-Track-Duo-Fix

**언어:** [English](README.md) · 한국어

## 권장: Microsoft USB Audio (`usbaudio.sys`)

Duo 는 **USB Audio Class 1.0** 입니다. 2013 Avid 패키지(`AvidFastTrackDuo.sys`)가 Windows inbox 드라이버보다 순위가 높아지며, 모던 WASAPI teardown 에서 알려진 **BSoD**(`+0x1849d`)의 원인입니다. **권장 해결:** 그 `.sys` 를 쓰지 않고 **Microsoft `usbaudio.sys`** 에 연결합니다.

| Release 파일 | 용도 |
|--------------|------|
| **`Fast-Track-Duo-USBAudio.exe`** | **이것을 설치 (권장).** Avid OEM 순위를 제거하고 inbox USB Audio 로 바인딩 |

```text
1. Fast-Track-Duo-USBAudio.exe 실행 (UAC)
2. 재부팅 요구 / Verify 실패 시 재부팅 후 필요하면 재실행
3. 서비스 = usbaudio 확인 (AVIDUSBFASTTRACKDUO 가 아니어야 함)
4. 공간 음향 Off · 향상 효과 Off · 가능하면 USB 2.0
```

저장소에서 동일 로직:

```powershell
sudo .\native-driver\usbaudio\Install-UsbAudio.cmd
.\native-driver\usbaudio\Verify-UsbAudio.ps1   # PASS: bound to usbaudio
```

설명: [`native-driver/README.md`](native-driver/README.md) · 상황별 선택: [`RELEASE_NOTES.md`](RELEASE_NOTES.md).

---

Avid **Fast Track Duo** 공식 **1.0.4** (`AvidFastTrackDuo.sys` 5.10.0.3505, 2013) 의 **간헐적 무음** / **오디오 BSoD** 완화 프로젝트입니다.

## 다운로드 (GitHub Releases)

버전 태그(`v1.0.0` …) 또는 **Release packages** 워크플로.

| 파일 | 사용 시점 |
|------|-----------|
| **`Fast-Track-Duo-USBAudio.exe`** | **기본.** Avid `.sys` → Microsoft USB Audio 클래스 드라이버 |
| **`1.0.4-patch.exe`** | 공식 **1.0.4** `.sys` 유지 — INF/APO 하드닝만 |
| **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** | 커뮤니티 **드라이버 1.0.5** 클린 설치 (수정 INF + **원본 Avid `.sys`**) |

로컬 빌드:

```powershell
pwsh -File packaging/build.ps1
# dist\ 에 Fast-Track-Duo-USBAudio.exe 포함
```

## 증상 → 원인 (요약)

| 증상 | 원인 |
|------|------|
| Chrome/Firefox 미디어 재생 중 탭 닫기·URL 변경 후 간헐적으로 **모든** 소리가 안 남. 공간 음향을 바꾸면 다시 남 | 재고 INF 가 **Microsoft Audio Home Theater Effects** (`mssysfx` / `FX\0`) 를 붙임. 공간음향·APO 재구성이 걸린 사용자 모드 오디오 그래프를 풀면서 “토글하면 복구”처럼 보임 |
| 스트리밍 중 Firefox 탭 주소 변경 시 BSoD | 커널 드라이버 `AvidFastTrackDuo.sys` 오프셋 **`+0x1849d`** 에서 잘못된/paged 버퍼를 DISPATCH_LEVEL 로 읽음 (`0xD1` / `0xA`) |

아래 근거 발췌에는 호스트 경로·계정·장치 instance ID 를 넣지 않았습니다. 전체 정리: [analysis/FINDINGS.md](analysis/FINDINGS.md)

---

## 왜 이런 문제가 생기는가 (상세)

### 1. 2013년 USB Audio KS 미니드라이버를 2020년대 OS 위에서 돌림

Fast Track Duo Windows 패키지는 WDM/Kernel Streaming 미니드라이버(`AvidFastTrackDuo.sys`)와, 이를 Windows 오디오 스택에 묶는 INF 로 구성됩니다. 당시 설계가 전제하던 환경은 대략 다음과 같습니다.

- 지금 Chromium/Gecko 미디어 스택처럼 **WASAPI 클라이언트를 매우 빠르게** 만들고 부수지 않음
- 오늘날의 Spatial Sound + APO 그래프가 아니라, 예전 **시스템 효과(LFX/GFX)** 모델
- 크로스 서명 커널 드라이버를 비교적 관대하게 받아 주던 코드 서명 규칙

Windows 11 에서도 바이너리는 로드되는 경우가 많지만, **버퍼 수명·동시성 가정은 더 이상 브라우저의 스트림 생성/해제 패턴과 맞지 않습니다.**

### 2. BSoD: elevated IRQL 에서의 use-after-free / 잘못된 버퍼 접근

탭 이동·닫기가 일어나면 브라우저는 WASAPI 클라이언트를 급히 정리합니다. Windows 는 핀/스트림을 멈추고 관련 버퍼를 해제하거나 페이지아웃할 수 있습니다. 그 사이 Duo 드라이버의 렌더 경로는 여전히 DPC / 높은 IRQL 에서 **샘플 변환 루프**를 돌릴 수 있습니다.

트리아지 덤프의 WinDbg 발췌 (모듈·오프셋만):

```
IMAGE_NAME:   AvidFastTrackDuo.sys
SYMBOL_NAME:  AvidFastTrackDuo+1849d
IP_IN_PAGED_CODE:
  AvidFastTrackDuo+1849d
  add eax, dword ptr [rbx]
PROCESS_NAME: System
FAILURE_BUCKET_ID: AV_AvidFastTrackDuo!unknown_function
```

파일 RVA `0x1849d` 의 바이트는 `03 03 48 83 c3 04 c1 f8 08 …` 로 시작하며, 요지는 “`[rbx]` 에서 PCM dword 를 읽어 출력 버퍼에 넣는다”입니다. IRQL 이 DISPATCH_LEVEL(`2`) 인 상태에서 `rbx` 가 이미 해제되었거나 resident 하지 않은 메모리를 가리키면 페이지 폴트가 나고, Windows 는 이를 다음으로 바꿉니다.

- `0xD1` `DRIVER_IRQL_NOT_LESS_OR_EQUAL`
- 또는 `0xA` `IRQL_NOT_LESS_OR_EQUAL`

여러 덤프가 **같은** 오프셋 `AvidFastTrackDuo+0x1849d` 에서 고장 났습니다. 일회성 메모리 오류라기보다, 독점 `.sys` 안의 **고정된 버그 지점**이라는 증거가 됩니다.

즉 BSoD 의 본질은 “Firefox 버그”가 아니라, **모던 브라우저의 빠른 스트림 해제와 레거시 커널 오디오 코드의 레이스**입니다.

### 3. 무음: 구형 Home Theater APO 와 Spatial Sound 의 충돌

커널 UAF 와 별개로, **재고 INF** 는 렌더 인터페이스에 Microsoft 구형 Home Theater 효과 체인을 등록합니다.

```
Needs=KS.Registration,WDMAUDIO.Registration,mssysfx.CopyFilesAndRegister
...
HKR,"FX\\0",%PKEY_FriendlyName%,,%FX_FriendlyName%
HKR,"FX\\0",%PKEY_FX_PreMixClsid%,,%FX_PREMIX_CLSID%
HKR,"FX\\0",%PKEY_FX_PostMixClsid%,,%FX_POSTMIX_CLSID%
...
FX_FriendlyName = "Microsoft Audio Home Theater Effects"
```

이 항목들은 DeviceClasses(`FX\0`, 종종 `MSFX` 로 미러링)에 들어가고 MMDevices `FxProperties` 로 이어집니다. Windows 10/11 에서는 그 옆에 **공간 음향(Spatial Sound)** 과 최신 APO 파이프라인이 함께 존재합니다.

사용자에게 보이는 증상과 맞는 실패 시나리오는 대략 다음과 같습니다.

1. 브라우저가 그래프 한가운데에서 스트림을 멈춤 (탭 닫기 / 주소 변경).
2. 공유 모드 Audio Engine + 레거시 FX + Spatial 처리가 엔드포인트 그래프를 **막힌 상태**로 남김 (어떤 앱의 소리도 안 남).
3. 공간 음향을 바꾸면 APO / 엔드포인트 구성이 다시 올라감 → 다음 나쁜 teardown 전까지 소리가 돌아옴.

SysFx 비활성 DWORD 만 `1` 로 두는 것으로는 부족한 경우가 많습니다. disable 비트는 켜져 있는데 Premix/Postmix CLSID 와 DeviceClasses `FX\0` 은 그대로라, 문제 있는 attach 경로가 남을 수 있습니다.

### 4. 왜 “.sys 만 고치면 되지”가 원클릭으로 안 되는가

Avid 바이너리 안의 `+0x1849d` 를 고치려면 **WHCP 인증** 재빌드가 필요합니다. 이 저장소는:

- **권장:** **`Fast-Track-Duo-USBAudio.exe`** — Microsoft `usbaudio.sys` 바인딩 (Avid `.sys` 미사용 → 해당 UAF 미적재)
- 전용 스택이 필요한 사용자를 위해 **1.0.4-patch** / **드라이버 1.0.5** (INF/APO 만)도 유지
- 해킹된 미서명 `.sys` 바이너리 패치는 **배포하지 않음**

---

## 설치

### A) 권장 → USB Audio 클래스

1. **`Fast-Track-Duo-USBAudio.exe`** 실행 (UAC).
2. 재부팅이 필요하면 수행 후 서비스 **`usbaudio`** 확인.
3. 공간 음향 Off + 향상 효과 Off · USB 2.0 권장.

소스: [`native-driver/usbaudio`](native-driver/usbaudio).

### B) 공식 1.0.4 유지 → 패치만

1. **`1.0.4-patch.exe`** 실행 (UAC).
2. 공간 음향 Off + 향상 효과 Off.

소스: [`patch/Install-Patch.cmd`](patch/Install-Patch.cmd).

### C) 클린 설치 → Driver Fix 1.0.0 (여전히 Avid `.sys`)

1. **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** 실행 (UAC).
2. 수정 INF 때문에 메모리 무결성 끄기 / testsigning 이 필요할 수 있음.

### 설치 후 한 번

1. **설정 → 시스템 → 소리 → Duo → 공간 음향 = 끄기**
2. 제어판 **소리** → Duo → **향상 효과 → 모두 사용 안 함**
3. 큰 Windows 업데이트 후 `Verify-UsbAudio.ps1` 로 재확인하거나 증상이 있으면 해당 exe 재실행

---

## 저장소 구성

```
native-driver/usbaudio/   # 권장 Microsoft usbaudio 바인딩 (+ 릴리스 EXE 페이로드)
patch/                    # 1.0.4 인플레이스 패치 소스
driver/1.0.5/             # 커뮤니티 드라이버 1.0.5 (INF + 공식 .sys/.cat)
packaging/                # ExeHost + build.ps1 → dist/*.exe
.github/workflows/        # 태그/수동 → GitHub Release 업로드
analysis/FINDINGS.md
README.md / README.ko.md
```

## 한계

- **`Fast-Track-Duo-USBAudio.exe`** 는 Avid `.sys` 를 로드하지 않아 해당 UAF 를 피합니다. 2013 전용 믹서 기능과 100% 동등하지 않을 수 있습니다.
- 레거시 패치 / 1.0.5 경로는 `.sys` 내부 `+0x1849d` 를 **고치지 않습니다**.
- **Driver_fix** exe 는 수정 INF 때문에 서명 정책 완화가 필요할 수 있습니다.
