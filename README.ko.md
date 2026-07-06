# Momenterm

[English README](README.md)

Momenterm은 터미널 중심으로 일하지만 IDE 수준의 코드 리뷰 화면도 필요한 사람을 위한 네이티브 macOS 터미널 겸 코드 리뷰 워크벤치입니다.

빠른 터미널, 저장소 탐색, Git diff 리뷰, 파일 트리, 히스토리, HTTP 클라이언트, 에이전트 알림을 하나의 AppKit 창에 모았습니다. Electron, 번들 Node 런타임, 브라우저 앱 셸은 포함하지 않습니다.

## 왜 Momenterm인가?

- **한 창에서 끝냅니다.** 터미널, IDE, 브라우저, 리뷰 도구를 오가며 맥락을 잃지 않고 터미널 패널, 파일, diff, 히스토리, 리뷰 노트를 함께 봅니다.
- **터미널이 중심입니다.** 기본 워크벤치는 libghostty 기반 네이티브 터미널이며 탭, 분할 패널, 워크스페이스별 터미널 상태, `~`에서 시작하는 새 탭을 지원합니다.
- **IDE를 열지 않아도 IDE식 리뷰가 됩니다.** F7/Shift+F7로 실제 변경 블록을 이동하고, diff는 IntelliJ/Darcula 스타일 하이라이트와 라인 넘버 gutter를 사용합니다.
- **로컬 우선입니다.** Swift가 Git diff, 소스 목록, Git 히스토리, HTTP 요청 화면, viewed 표시, 리뷰 코멘트, 설정을 로컬에서 처리합니다.
- **에이전트 작업에 맞춰져 있습니다.** 터미널 OSC 시퀀스의 "agent waiting / done" 상태를 패널 링과 워크스페이스 알림으로 표시하고, `Cmd+Shift+U`로 다음 unread 패널로 이동합니다.
- **Git 폴더가 아니어도 유용합니다.** Non-Git 폴더도 터미널 우선 워크스페이스로 열고, Files는 폴더를 탐색하며 Changes는 조용히 실패하지 않고 안내를 보여줍니다.

## 빠른 설치

### 방법 1: DMG 다운로드

미리 빌드된 바이너리는 [Releases](https://github.com/happy-nut/momenterm/releases) 페이지에 올라갑니다.

1. 최신 릴리즈에서 `Momenterm.dmg`를 다운로드합니다.
2. DMG를 열고 `Momenterm.app`을 Applications로 드래그합니다.
3. 첫 실행 시 **Momenterm을 우클릭(Control-click) → Open**을 누르고, 대화상자에서 **Open**을 확인합니다. 이후 macOS가 이 선택을 기억합니다.

Momenterm은 아직 코드 서명과 notarization을 하지 않았기 때문에 macOS가 "확인되지 않은 개발자" 경고를 띄울 수 있습니다. 그래도 열리지 않으면:

```bash
xattr -dr com.apple.quarantine /Applications/Momenterm.app
```

### 방법 2: 직접 빌드해서 설치

macOS 11 이상과 Xcode Command Line Tools가 필요합니다.

```bash
xcode-select --install
git clone https://github.com/happy-nut/momenterm.git
cd momenterm
./scripts/install-app.sh
open /Applications/Momenterm.app --args --repo /path/to/repo
```

첫 빌드 때 `scripts/build.sh`가 checksum으로 검증된 고정 버전의 libghostty 바이너리를 `.build/vendor`에 내려받습니다. 추가 설정은 필요 없습니다.

## 개발 실행

체크아웃한 저장소에서 직접 실행하려면:

```bash
swift run Momenterm --repo /path/to/repo
```

SwiftPM이 Command Line Tools의 `xctest`를 찾지 못하는 환경에서는 직접 컴파일 스크립트를 사용합니다.

```bash
./scripts/run.sh --repo /path/to/repo
```

`--repo` 없이 실행하면 Momenterm이 시작 화면을 열고 앱 안에서 폴더를 선택할 수 있습니다.

## 주요 기능

- **터미널 워크벤치:** 네이티브 탭, 분할 패널, 워크스페이스별 터미널 상태, 셸 통합, 컴팩트한 패널 컨트롤.
- **Changes:** 로컬 Git diff 리뷰, 변경 블록 이동, viewed 표시, 영구 리뷰 코멘트, IntelliJ 스타일 라인 넘버 gutter.
- **Files:** 저장소 파일 트리, 소스 미리보기, 라인 넘버 코드 뷰, Quick Open, Recent Files, Find in Files.
- **History:** 네이티브 Git 히스토리와 커밋 diff 확인.
- **HTTP 요청:** IntelliJ `.http` 요청 실행과 environment 파일 지원.
- **Settings:** 리뷰 동작, prompt merge 텍스트, 테마, 코드 폰트 크기 설정.

## 검증

```bash
./scripts/build.sh
./scripts/smoke.sh /path/to/repo
./scripts/native-guard-smoke.sh
./scripts/ab-smoke.sh
./scripts/perf-smoke.sh
./scripts/pty-smoke.sh /path/to/repo
./scripts/launch-smoke.sh /path/to/repo
```

## 패키징

```bash
./scripts/package-app.sh
open .build/Momenterm.app --args --repo /path/to/repo
```

```bash
./scripts/package-dmg.sh
open .build/Momenterm.dmg
```

패키징 스크립트는 자체 실행 가능한 앱 번들과 Applications로 드래그하는 DMG를 만듭니다. Node, Electron, JS 앱 런타임은 번들하지 않습니다.

## 문서

- [docs/workspace-plan.md](docs/workspace-plan.md) — 워크스페이스와 에이전트 알림 설계.
- [docs/native-capabilities.md](docs/native-capabilities.md) — 네이티브 리뷰 기능 로그와 forbidden runtime marker scan 계약.
- [docs/ui-review.md](docs/ui-review.md) — Darcula UI 시각 리뷰.
- [docs/maintenance-backlog.md](docs/maintenance-backlog.md) — 우선순위가 정리된 유지보수 백로그.
- [docs/maintenance-checklist.md](docs/maintenance-checklist.md) — clean-code, SOLID, UI, 검증 게이트.
- [docs/refactor-plan.md](docs/refactor-plan.md) — 대형 View Controller 분해 계획.
- [docs/shortcuts.md](docs/shortcuts.md) — 키보드 단축키 레퍼런스.

## 다음 실험

1. 배포용 코드 서명과 notarization 추가.
2. 렌더링된 리뷰 UI에 대한 시각 회귀 스크린샷 추가.

## 라이선스

Momenterm은 [MIT License](LICENSE)로 배포됩니다. 번들된 Monaco Editor, marked, libghostty, codicons는 각자의 라이선스를 유지합니다. 자세한 내용은 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 참고하세요.
