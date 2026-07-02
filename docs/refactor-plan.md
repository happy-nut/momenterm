# Momenterm 리팩토링 플랜 — 버그가 스며들지 못하는 단순한 구조

> 작성일: 2026-07-01 · 대상 브랜치: main · 상태: 진행 중 (Phase 0 착수)

## 목표

변경의 파급을 구조로 차단해 **버그가 태어날 자리를 없애는 것**. 기능 재작성이 아니라,
이미 건강한 코어는 그대로 두고 **God View Controller 하나를 점진적으로 해체**한다.
각 단계는 독립적으로 안전하며, 언제 멈춰도 이전보다 나은 상태다 (Strangler 방식).

## 진단 (정적 분석 기반)

### 이미 건강한 부분 — 건드리지 않는다
- `try!` / `as!` = **전 파일 0개**, 강제 언랩 위험 거의 없음
- 전역 싱글톤 남용 없음 (`static ... shared` 사실상 없음)
- 코어 로직 레이어가 이미 단일 책임 + `protocol` 추상화로 분리됨:
  `NativeReviewCore`, `NativeHttpClient`, `NativeSourceCollector`, `NativePtyManager`,
  `NativeGitClient`(protocol `GitClient`), `UnifiedDiffParser`, `NativeTerminalCore` — 각 50~500줄

### 문제가 집중된 단 하나의 파일 — `Sources/Momenterm/MainWindowController.swift`

| 지표 | 수치 | 버그가 스며드는 메커니즘 |
|------|-----:|------|
| 파일 크기 | 14,552줄 | 한 기능 수정에 파일 전체를 뒤져야 함 → 호출 지점 누락 |
| 함수 | 847개 | 같은 네임스페이스 → 잘못된 헬퍼 호출, 탐색 비용 폭발 |
| 인스턴스 `var` (가변 상태) | 160개 | 어떤 함수든 어떤 상태든 변경 가능 → A기능 수정이 B기능을 깨뜨림 |
| 한 파일에 중첩된 타입 | 21개 | 터미널 에뮬레이터·CSV·Markdown·Syntax·Theme·Diff·FileTree·QuickOpen·Settings가 한 클래스에 |
| `// MARK:` 구분선 | 0개 | 14.5k줄에 논리적 경계가 하나도 없음 |
| `ForSmokeTest` 훅 함수/참조 | 227개 / 287곳 | 유닛 테스트 부재 → 프로덕션 클래스에 테스트 관측 훅을 심음 |
| `DispatchQueue` / `Timer` | 24 / 8 | `@MainActor` 경계 없는 수동 동시성 → 상태 경합 |
| XCTest 유닛 테스트 | 0개 | 회귀를 자동으로 잡을 안전망 부재 (smoke 실행파일만 존재) |

핵심: **로직은 깨끗한데 UI·상태·조정·터미널·렌더링이 전부 한 클래스에 뭉쳐** 변경의 파급을 막을 경계가 없다.

## 목표 구조 원칙

1. **작은 표면적** — 각 타입이 적은 상태 + 적은 협력자만 소유. 변경 국소화.
2. **상태 소유권 분할** — 160개 흩어진 `var`를 도메인별 컨트롤러가 나눠 소유.
3. **순수 로직 분리** — I/O·UI에서 순수 변환(파싱·렌더·필터)을 떼어내 유닛 테스트 가능하게. → `ForSmokeTest` 훅 227개 불필요화.
4. **동시성 경계 명시** — `@MainActor`로 UI 상태를 단일 스레드에 고정.
5. **컴파일 타임 계약** — enum·타입으로 상태 표현 (이미 `try!`/`as!` 0이라 기반 양호).

## 타깃 아키텍처

```
MainWindowController  (얇은 Coordinator, 목표 300~500줄)
   │  자식 컨트롤러 생성·연결, 창 수명주기, 단축키 라우팅만
   ├─ DiffReviewController      selectedDiff*, viewedFilePaths, reviewNotes, inlineReview*
   ├─ FileTreeController        fileListing*, fileTreeExpandedFolders, visibleFileTreeRows
   ├─ QuickOpenController       quickOpen* (12개 var)
   ├─ TerminalTabsController    terminalTabs, sessions, activeTerminal*, pendingPtyData
   ├─ WorkspaceController       workspaces, activeWorkspacePath, workspaceRail*
   ├─ HttpRunnerController      httpResponse*, httpRunButtons
   ├─ SettingsController        persistedSettings, settingsPrompt*
   └─ OverlayLayoutController   overlay*Constraint (30여 개 오토레이아웃 제약)

순수 로직 (별도 파일 + 격리 스모크 대상):
   ├─ TerminalEmulator          Style/Cell/screen/scrollback/cursor (VT 파싱 = 순수)
   ├─ NativeMarkdownRenderer    입력 → HTML  (이미 enum, 파일만 분리)
   ├─ NativeCsvRenderer         입력 → HTML
   ├─ NativeSyntaxHighlighter   토큰화 규칙
   └─ NativeTheme               테마 토큰 (값 타입, 주입)
```

## 도메인 클러스터 매핑 (160 var + 847 func → 제안 컨트롤러)

| 도메인 | var | func | 함수 라인 | smoke훅 | 성격 |
|--------|----:|-----:|--------:|-------:|------|
| Misc (미분류) | 50 | 356 | 5,543 | 46 | 실제론 터미널 에뮬레이터+렌더러+인라인뷰 혼재 |
| Terminal | 13 | 151 | 2,135 | 63 | VT 파싱·그리드·스크롤백 (순수 로직 다수) |
| Layout/Overlay | 31 | 89 | 1,902 | 39 | 오토레이아웃 제약 — 결합 핫스팟 |
| DiffReview | 17 | 71 | 1,070 | 20 | diff 선택·리뷰노트·인라인코멘트 |
| Workspace | 5 | 55 | 591 | 15 | |
| Memo/Prompt | 4 | 47 | 565 | 20 | |
| Settings | 4 | 32 | 485 | 11 | |
| FileTree/Source | 8 | 19 | 378 | 8 | |
| Http·History·Document·QuickOpen | 23 | 27 | 348 | 5 | 소규모, 추출 쉬움 |
| Theme | 5 | 0 | 0 | 0 | 순수 데이터, 모두가 읽기만 |

## 도메인 간 결합 분석 (분리 시 끊어야 할 지점)

상위 결합 (도메인 A의 함수가 도메인 B의 var를 참조하는 함수 수):

```
 56  Misc → Theme            37  Misc → Layout/Overlay     34  Misc → QuickOpen
 27  Misc → FileTree/Source  24  Memo → Layout/Overlay     23  DiffReview → Layout/Overlay
 21  Terminal → Misc         17  Misc → DiffReview         16  Terminal → Workspace
 14  Workspace → Layout      14  Layout → Theme            12  Terminal → Theme / Settings → Theme
```

세 가지 통찰:
1. **Theme = 최대 결합원이지만 가장 쉬운 승리.** `→ Theme` 결합이 100개 넘음. 그런데 Theme는 var 5개 + 함수 0개 = 순수 읽기 데이터. 값 타입으로 빼서 주입하면 100+ 결합이 위험 없이 정리됨.
2. **Misc 5,543줄은 미지수가 아니라 숨은 컴포넌트.** Misc var 50개의 실제 정체: 터미널 에뮬레이터 상태 ~20개(`screen, scrollback, cursorRow, savedCursor, alternateScreen, foreground, bold...`), 인라인 에디터/마크다운 뷰 콜백 ~12개(`onKeyDown, onInput, onPaste, onTextChange, renderMarkdown...`), 나머지 coordinator + smoke 훅. 대부분 순수 로직이거나 독립 뷰 → 추출 경계 명확.
3. **Layout/Overlay = 진짜 위험 지대.** 모든 기능이 overlay 오토레이아웃 제약(31 var)을 직접 만짐. God object의 핵심. 각 컨트롤러가 자기 제약을 소유하도록 재배치하는 게 가장 조심스러움 → 맨 마지막.

## 실행 청사진 (위험 낮음 → 높음, 순수 → 얽힘)

| # | 대상 | 성격 | 위험 | 테스트 이득 |
|---|------|------|:----:|:----:|
| 0 | **안전망**: 격리 스모크 실행파일 확장 (xctest 미가용) | 인프라 | 🟢 | 전제조건 |
| 1 | **Theme 주입** | 순수 데이터 | 🟢 최저 | 100+ 결합 정리 |
| 2 | **TerminalEmulator 추출** | 순수 로직 | 🟢 낮음 | 🔥 최고 (63 smoke훅→유닛) |
| 3 | **렌더러 3종** (CSV/MD/Syntax) | 순수 I/O | 🟢 낮음 | 높음 |
| 4 | **인라인 에디터/뷰 컴포넌트** | 독립 NSView | 🟢 낮음 | 중 |
| 5 | **소규모 컨트롤러** (FileTree→QuickOpen→Http→Settings) | UI+상태 | 🟡 중 | 중 |
| 6 | **대형 컨트롤러** (DiffReview→Memo→Workspace→TerminalTabs) | UI+상태 | 🟡 중 | 중 |
| 7 | **Layout/Overlay 재배치** | 결합 핫스팟 | 🔴 높음 | 낮음 |

## 검증 게이트 (매 단계 공통, 하나라도 red면 그 단계 미완료)

> 환경 제약: 이 머신은 Command Line Tools만 있어 `xctest`가 없다(`swift test` 불가). 모든 빌드는
> `swiftc` 직접 컴파일이며, 테스트는 기존 스모크처럼 필요한 소스만 격리 컴파일 → 실행 →
> `guard/exit(1)` 방식으로 만든다. 순수 타입을 별도 파일로 빼내는 것이 곧 격리 테스트를 가능하게 한다.

- 신규 유닛 스모크 실행파일 통과 (`swiftc` 격리 컴파일)
- `scripts/smoke.sh` + `scripts/parity-smoke.mjs` + `scripts/ab-parity-smoke.mjs` 통과
- `docs/parity-gap.md`의 런타임 마커 스캔 유지 (Electron/Node/Monacori 마커 부재)
- MainWindowController 라인 수가 단계마다 감소 (진행 지표)

## 뉴 아키텍처 재설계 — CodePaneController (공유 뷰 소유권 격리)

> #5~#7을 대체하는 방향. 사용자 결정(2026-07-01): 공유 뷰 소유권을 먼저 재설계한 뒤
> 그 위에 도메인 컨트롤러를 올린다. Http 파일럿에서 delegate 완전 분리가 20+ 인터페이스로
> 역효과임을 코드로 확인한 결과다.

### 근본 원인 (측정값)
- `oldTextView`(110 refs) · `newTextView`(85 refs) — 둘 다 `NativeCodeTextView` 인스턴스, MWC가 소유(L434-435)
- `overlayDiffSplitView`(34) · `sourcePreviewScrollView`(26) · `overlaySubtitleLabel`(30)
- **68개 함수**가 old/newTextView를 직접 조작 — diff·source·http·history·quickopen·review 모든
  오버레이 도메인의 공용 디스플레이 표면. 이 두 뷰가 공유 자원이라 개별 도메인이 깨끗이 분리 불가.

### 설계: CodePaneController
소유: `oldTextView`, `newTextView`, `sourcePreviewScrollView`, `overlayDiffSplitView`, 거터 버튼.
API 표면(측정된 조작 기반):
- 콘텐츠: `setDiff(old:new:)`, `setSingle(_:)`, `text(pane:)` — `.string`(52), `.textStorage`(41)
- 커서: `placeCursor(pane:line:focus:)`, `cursorLine(pane:)`, `setCursorHidden(_:)` — `.reviewCursor*`(12)
- 스크롤: `scrollToTop(pane:)`, `scrollRangeToVisible(_:)` — (8+1)
- 레이아웃: `setSideBySide(_:)`, `setSinglePaneVisible(_:)`, `setInset(_:)`
- 거터: `installButtons(_:)`, `clearButtons()` — http run 버튼
도메인 컨트롤러는 이 API만 의존 → 뷰 직접 결합 제거.

### 마이그레이션 (각 스텝 후 백업 + 전체 빌드 + 스모크 5종 green)
- **Step A (저위험)**: CodePaneController 생성 + 뷰 소유권 이전. MWC는 computed 위임 프로퍼티
  (`var oldTextView: NativeCodeTextView { codePane.oldTextView }`)로 임시 접근 → 기존 195 refs 무변경.
- **Step B (점진)**: 도메인별로 직접 뷰 접근을 API로 교체 (diff → source → http → history → quickopen → review).
- **Step C**: 도메인 컨트롤러 추출 (이제 CodePaneController API만 의존하므로 깨끗).

### 리스크
- 대규모(195 refs, 68 함수), 다세션. 런타임 UI라 스모크 커버리지 제한(다수가 `*ForSmokeTest` 훅 경유).
- 각 스텝을 작게 쪼개고 매 스텝 백업 + 전체 빌드 + 스모크 5종.

## 진행 상태

- [x] Phase 0 · 안전망 (격리 스모크 실행파일 — xctest 미가용 환경) — `scripts/theme-smoke.sh` 패턴 확립
- [x] #1 Theme 주입 — `NativeTheme.swift`로 분리, 빌드/코어스모크/테마스모크 green
- [x] #2 TerminalEmulator 추출 — `NativeAnsiRenderer.swift` 분리(−1,116L), 죽은코드 `NativeLegacyAnsiRenderer` 339L 삭제, `ansi-smoke.sh` green
- [x] #3 렌더러 3종 분리 — `NativeContentRenderers.swift`(CSV/Markdown/Syntax, −446L), `renderer-smoke.sh` green
- [x] #4 인라인 에디터/뷰 컴포넌트 분리 — `NativeTextViews.swift`(8개 NSView 서브클래스, −918L), `textviews-smoke.sh`(격리 타입체크) green
- [x] 뉴 아키텍처 Step A: CodePaneController 생성 + 공유 뷰(old/newTextView) 소유권 이전 — 빌드/스모크5종 green
- [~] 뉴 아키텍처 Step B: CodePane API 도입 + **http 도메인 교체 완료**(파일럿 — 직접접근 0 / 빌드·스모크5종 green). 나머지 도메인(diff→source→history→quickopen→review) 남음
- [ ] 뉴 아키텍처 Step C: 도메인 컨트롤러 추출 (HttpRunner/DiffReview/… — CodePane API 의존)
