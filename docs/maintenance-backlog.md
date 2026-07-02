# Momenterm 유지보수 백로그

> 작성일: 2026-07-03 · 대상 브랜치: main · 상태: Tier 0 진행 중
>
> 이 문서는 유지보수 개선 작업의 **마스터 백로그**다. God Object 해체의 상세
> 실행 계획은 [refactor-plan.md](refactor-plan.md), 게이트 체크리스트는
> [maintenance-checklist.md](maintenance-checklist.md)에 있다.

## 진단 요약 (2026-07-03 정적 분석)

세 관점의 병렬 분석 결과, 이 코드베이스는 **코어 로직이 건강**하다:
`try!`/`as!`/force-unwrap 프로덕션 0건, LSP 진단 clean, 코어 레이어가
`protocol` 추상화로 분리됨(`NativeReviewCore`, `NativeHttpClient`,
`NativeSourceCollector`, `NativePtyManager`, `GitClient`, `UnifiedDiffParser`,
`NativeTerminalCore`). 유지보수의 어려움은 거의 전부 두 지점에 집중된다:

1. **God Object** — `MainWindowController.swift` 13,764줄(전체의 절반 이상).
   클래스 본체 13,508줄(98%), 인스턴스 프로퍼티 ~189개(가변 var 169개 private),
   메서드 733개, 중첩 타입 13개, `// MARK:` 4개, `extension` 0개.
   10개 이상 도메인(터미널/PTY·diff·오버레이·워크스페이스·파일트리·퀵오픈·
   히스토리·설정·리뷰·메모)이 한 클래스에 융합.
2. **안전망 부재** — XCTest 0개. 격리 스모크 22개가 유일한 게이트이나 단일
   실행 진입점(오케스트레이터) 없음, CI 없음. 프로덕션 클래스에 `*ForSmokeTest`
   관측 훅 305곳(MainWindowController에 277곳)이 릴리스 빌드에 포함됨.

## Tier 0 — 즉시 처리 (저비용·고효과, 후속 작업의 전제)

- [x] **0-1** `.omc/` git 추적 해제 + `.gitignore` 등록 — 운영 상태 파일 23개(60KB)가
      매 세션 diff 오염을 만들던 것 제거. (commit)
- [x] **0-2** `ForSmokeTest`/진단 메서드를 `#if DEBUG`로 격리 — 릴리스 바이너리에서
      테스트 훅 제거. 캡슐화 유지를 위해 **같은 파일 내** `#if DEBUG`로 감싸고
      (private→internal 완화 없음), `key-input-smoke.sh`에만 `-D DEBUG` 추가.
      파일 크기 축소는 Tier 2 도메인 추출에 위임. *(진행 중)*
- [x] **0-3** 신규 `SystemStatsBar.swift`(294줄) 커밋 — baseline 커밋에 흡수 완료.
- [x] **0-4** 빈 `Support/` 디렉토리 제거.

## Tier 1 — 안전망 구축 (리팩토링 전 필수)

- [ ] **1-1** 스모크 오케스트레이터 `scripts/smoke-all.sh` 신설 — 22개 `*-smoke.sh`를
      순회·집계·non-zero 전파하는 단일 진입점. (현재 `smoke.sh`는 core 하나만 실행)
- [ ] **1-2** GitHub Actions CI(`.github/workflows`) — macOS 러너에서 build + smoke-all.
      현재 `.github` 부재, 로컬 수동 실행이 유일한 게이트.
- [ ] **1-3** `MomentermSmoke` 죽은 타겟 정리(대응 스크립트 없음) + 스모크 실행 지침을
      문서 한 곳에 22개 전부 반영(README는 7개, checklist는 ~10개만 나열).

## Tier 2 — God Object 해체 (`MainWindowController`)

> 상세 실행 계획·도메인 클러스터 매핑·결합 분석은 [refactor-plan.md](refactor-plan.md).
> **완료**: Theme 주입, TerminalEmulator/렌더러/TextViews 추출, CodePaneController
> Step A, http 도메인 Step B. **남은 항목**:

- [ ] **2-1** [새 통찰] extension 파일 분할 우선 — `+Terminal`/`+Overlay`/`+Diff`/
      `+QuickOpen`/`+Settings`/`+History`/`+Review`/`+WorkspaceRail` (같은 타입, 여러
      파일). 상태 이동 없어 위험 0, 13k줄이 즉시 탐색 가능. 타입 추출의 발판.
- [ ] **2-2** `TerminalSession`·`TerminalTab`(중첩, 외부 컨트롤러 미참조) 최상위 타입 승격.
- [ ] **2-3** `TerminalPaneManager` 추출(`sessions`/`terminalTabs`/`activeTerminalId`/
      PTY-flush + `NativePtyManagerDelegate`). 최대 비-테스트 도메인(~2,310줄) 격리.
- [ ] **2-4** refactor-plan Step B 완료(diff→source→history→quickopen→review) + Step C
      도메인 컨트롤러 추출.
- [ ] **2-5** 거대 메서드 분해: `configureOverlay`(316), `handleShortcut`(311,
      enum/테이블 디스패치), `createTerminalPaneView`(240).
- [ ] **2-6** 중복 row/button 빌더 통합(`diffSidebarRowButton`·`historyRowButton`·
      `fileTreeRowButton` 등 9개 유사 메서드 → 공용 팩토리).
- [ ] **2-7** 흩어진 169개 private var 도메인별 캡슐화, 22개 캐시 `NSLayoutConstraint`를
      각 컨트롤러가 소유(Layout/Overlay는 결합 핫스팟 → 마지막).

## Tier 3 — 코드 품질 (중복·일관성·안전성)

- [ ] **3-1** `NativeReviewCore` 중복 제거 — git/non-git 판별 4줄 + branch 삼항식이
      `build()`(:48-64)·`fileListing()`(:137-146)에 완전 동일 → `resolveRoot`/
      `currentBranchName` 헬퍼. [HIGH]
- [ ] **3-2** `NativeReviewCore` 책임 분리 — worktree·diff·gitlog·`httpSend`·sha1·
      바이너리판별을 한 타입이 담당. `httpSend`는 `NativeHttpClient`로 이동(SRP). [HIGH]
- [ ] **3-3** 스모크 공용 지원 타겟(`SmokeSupport`) — non-git 픽스처/`expect()`/성공출력이
      KeyInput/Perf/Core에 복붙(prefix도 `non-git-`/`nongit-`로 갈림). [HIGH]
- [ ] **3-4** 매직 넘버 → 디자인 토큰 — `NativeDesignSystem` inset 토큰이 있는데
      `NativeTextViews`·`HttpRunnerController`는 리터럴 사용. 타이밍값(PTY 0.09/0.05,
      클럭 1.5) 명명 상수화. [MEDIUM]
- [ ] **3-5** 에러 처리 정책 — `try?` 남용(`NativeReviewCore` 14·`NativeSourceCollector`
      11). 전파와 silent-swallow 혼재 → 삼킬 지점에 근거 주석/로깅. [MEDIUM]
- [ ] **3-6** 구조적 로깅 도입 — GUI에 `os.Logger` 전무, CLI는 stderr write, 스모크는
      `print`/`fputs` 혼용. (임시 `momentermKeyDebug`도 이때 정리) [MEDIUM]
- [ ] **3-7** `Native*` 접두사 컨벤션 정리 — `SystemStatsSampler`·`LibGhosttyTerminalView`·
      `HttpRunnerController` 등이 규칙 이탈. [MEDIUM]
- [ ] **3-8** [안전성] `NativeAnsiRenderer:419` `removeSubrange` 경계 clamp 확인 +
      파서 fuzz 스모크. [MEDIUM]
- [ ] **3-9** 저순위: `JSONValue` private 확장 재정의 통합, `Process` 기동을 `Shell`
      래퍼로 통일, 임시디렉토리 API(`NSTemporaryDirectory` vs `FileManager`) 통일. [LOW]

## Tier 4 — 빌드·문서 현대화

- [ ] **4-1** `swift-tools-version` 5.4 → 상향, `.macOS(.v11)` 상향.
- [ ] **4-2** SPM ↔ `build.sh` 이중 빌드 정합성 — 스모크의 하드코딩 파일 목록 vs glob
      불일치. `xctest` 미가용 우회 사유 문서화.
- [ ] **4-3** libghostty 하드코딩 경로 문서화/파라미터화(재현성).
- [ ] **4-4** 문서 동기화 — "Monacori" 역사적 프레이밍 정리, `parity-gap.md`를 완료
      로그로 재분류, README에 미링크 문서 3종 연결.
- [ ] **4-5** 핵심 파일 주석 밀도 개선(`MainWindowController` 2.1%) — Tier 2 분할과 함께.

## 권장 순서

Tier 0(위생·테스트코드 격리) → Tier 1(안전망) → Tier 2(해체) 순서가 결정적이다.
`.omc` 정리로 diff를 깨끗이 하고, `ForSmokeTest`를 릴리스에서 걷어내고, CI+오케스트레이터로
안전망을 깐 **뒤에야** God Object 해체가 안전하게 검증된다. 코어 로직(Tier 3 대부분)은
이미 건강해 급하지 않다.
