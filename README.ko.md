<img src="assets/icon.svg" width="64" height="64" alt="">

# Fast-Track-Duo-Fix

**언어:** [English](README.md) · 한국어

Avid **Fast Track Duo** 공식 드라이버 **1.0.4** (`AvidFastTrackDuo.sys` 5.10.0.3505, 2013) 를 Windows 10/11 에서 쓸 때 나타나는 **간헐적 무음** / **오디오 관련 BSoD** 완화 패치입니다.

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

`+0x1849d` 를 제대로 고치려면 버퍼 수명 검증(취소 동기화, free 전 DPC 정지, NonPaged 상주 등)과 **WHCP 인증된** 드라이버 배포가 필요합니다. 2013년 크로스 서명 바이너리를 임의 수정한 결과물은 현재 Windows 코드 무결성이 기대하는 커널 이미지 규칙 밖입니다. 그래서 이 저장소는:

- INF/레지스트리 APO 경로는 **자름** (무음 완화, 나쁜 teardown 경로에 걸리는 스트레스 감소)
- 해킹된 미서명 `AvidFastTrackDuo.sys` 는 **배포하지 않음**

---

## 원클릭 패치 설치

### 사전 조건

- Windows 10/11 x64
- Fast Track Duo 드라이버 1.0.4 가 이미 설치되어 장치가 인식되는 상태
- 관리자 권한 (UAC)

### 설치

1. Duo 를 USB 에 연결합니다 (가능하면 USB 2.0 포트).
2. [`patch/Install-Patch.cmd`](patch/Install-Patch.cmd) 를 **더블클릭** 합니다.
3. UAC 에서 예를 누릅니다.
4. 로그에 `WORKER_DONE` 이 보이면 완료입니다. 로그는 `patch/logs/` 아래입니다 (git 제외).

또는 관리자 PowerShell:

```powershell
cd <repo>\patch
.\Install-Patch.ps1
```

설치 스크립트는 런타임에 머신 고유 이름을 찾습니다 (호스트 개인 정보는 하드코딩하지 않음):

- `DriverStore\FileRepository\avidfasttrackduo.inf_*`
- `VID_0B0F&PID_2036` / Fast Track Duo 가 들어 있는 `C:\Windows\INF\oem*.inf`
- 해당 USB ID 의 DeviceClasses `FX\0` · `MSFX`
- 속성에 Fast Track Duo 가 포함된 렌더 엔드포인트

### 설치 후 한 번만

1. **설정 → 시스템 → 소리 → Avid Fast Track Duo → 공간 음향 = 끄기**
2. 제어판 **소리** → Duo → 속성 → **향상 효과 → 모두 사용 안 함**
3. 큰 Windows 업데이트 후 증상이 다시 나오면 `Install-Patch.cmd` 를 다시 실행

### 패치가 바꾸는 것

| 계층 | 동작 |
|------|------|
| DriverStore + 게시된 `oem*.inf` | [`AvidFastTrackDuo.nofx.inf`](patch/AvidFastTrackDuo.nofx.inf) 로 교체 (`mssysfx` / `FX\0` 없음) |
| DeviceClasses | Duo `FX\0` / `MSFX` 제거 |
| MMDevices | Duo 렌더 엔드포인트 SysFx 비활성 |
| `AvidFastTrackDuo.sys` | 변경 없음 |

---

## 저장소 구성

```
patch/
  Install-Patch.cmd          # 원클릭 (UAC)
  Install-Patch.ps1          # 설치 로직
  AvidFastTrackDuo.nofx.inf  # Home Theater FX 제거 INF
  AvidFastTrackDuo.stock.inf # 원본 INF 백업
analysis/
  FINDINGS.md                # 근거 (개인정보 제외)
assets/
  icon.svg
README.md                    # English
README.ko.md                 # 한국어 (이 파일)
```

공식 설치 zip·추출물·미니덤프·호스트 경로 스크래치는 [`.gitignore`](.gitignore) 로 제외합니다.

## 한계

- `+0x1849d` 커널 UAF 자체는 고치지 않습니다.
- 수정한 미서명 `.sys` 는 최신 WHCP / 코드 무결성에서 로드되지 않습니다.
- 스트리밍 중 탭을 매우 빠르게 닫거나 주소를 바꾸는 동작은 가능하면 줄이는 것이 안전합니다.
