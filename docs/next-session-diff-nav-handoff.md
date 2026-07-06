# 다음 세션 핸드오프 — diff view 코드 네비게이션 + IntelliJ 패리티 잔여

Momenterm(네이티브 macOS Swift/AppKit 터미널+코드리뷰 앱)의 diff/파일 뷰에 IDE 기능을 이어서 구현한다.
에이전트에 위임하지 말고 직접 처리. 코드 변경 때마다 `./scripts/install-app.sh`로 `/Applications/Momenterm.app` 재설치(설치본으로 테스트). git add는 대상 파일만 명시(conductor 워킹트리에 병렬 변경 유입되니 `git add -A` 금지).

## 반드시 먼저 알아야 할 아키텍처 (이번 세션의 핵심 발견)
- Changes/Files 뷰는 **하이브리드**다: `renderDiffFile`(MainWindowController+ChangesReview.swift)이 네이티브 `codePane`(NSTextView)을 채운 뒤, `hybridWebViewsAvailable`면 `showHybridDiffPane()`이 **네이티브 split(`overlayDiffSplitView`)을 숨기고 Monaco(`diffHybridView`)를 표시**한다. 파일 뷰는 `fileHybridView`(code-viewer.html).
- 따라서 리뷰 커서/코멘트/네비게이션 등 **모든 diff-view 인터랙션은 Monaco(JS) 위에서 구현해야** 한다. 네이티브 `codePane`에만 그리면 설치본에선 안 보인다. (스모크는 webviews 번들이 없어 `hybridWebViewsAvailable=false` → 네이티브 폴백만 검증됨 → **Monaco 경로는 스모크 런타임 검증 불가**, 프리뷰/수동 확인 필요.)
- JS↔Swift 브리지: Swift→JS는 `diffHybridView.postJSON([...])`(내부적으로 `window.postMessage`), JS→Swift는 `window.webkit.messageHandlers.<name>.postMessage(data)` + Swift `diffHybridView.registerMessageHandler(name:) { body in ... }`(등록은 MainWindowController.swift `configureOverlay` 근처, `diffHybridView.loadFromBundle` 뒤).
- 이미 이렇게 구현된 것(참고 패턴): 리뷰 커서(`setReviewCursor`), 헝크 이동(F7/Shift+F7 → JS keydown → `reviewNavigate` → `selectReviewTarget`), 마지막-헝크 힌트(`showLastHunkHint`), 코멘트(`setComments` → Monaco view zone, `reviewComment`/`reviewDeleteComment`), Darcula 테마(`defineDarculaTheme`), Shift+Tab 패널 전환. Monaco 모델은 훅에서 재구성한 내용이라 Monaco 라인≠파일 라인 → `hybridModifiedFileLines`(라인 매핑)로 왕복. 메모리 `hybrid-webview-smoke-fallback` 참고.

## 작업 1 — Cmd+B: Find Usages를 Monaco에서 동작하게 (작음, 안전)
- `findUsagesUnderCursor()`(MainWindowController.swift, Cmd+B에 이미 바인딩 case "b")는 **네이티브 커서**(`activeInlineReviewCodeView().reviewCursorLocation`)에서 단어를 뽑아 `openQuickOpen(mode:.content, initialQuery: word)`(Find-in-Files)를 연다 → Monaco 뷰에선 커서가 네이티브 숨은 뷰에 있어 실패.
- 구현: `diff-viewer.html`(+`code-viewer.html`)의 `document keydown`에서 `(e.metaKey)&&e.key==='b'` → `editor.getModel().getWordAtPosition(editor.getPosition())`로 단어 추출 → `postToNative('findUsages',{word})` + preventDefault. Swift에서 `diffHybridView`(+`fileHybridView`)에 `registerMessageHandler("findUsages")` → `openQuickOpen(mode:.content, initialQuery: word)`.
- 주의: Monaco가 포커스면 Cmd+B가 앱 로컬 키모니터(handleShortcut)에 안 닿으니 반드시 JS keydown에서 잡아 브리지.

## 작업 2 — Cmd+↓: Go to Declaration (신규)
- Monaco 커서 단어 → `postToNative('goToDeclaration',{word})`. Swift 핸들러가 워크스페이스 루트(`activeWorkspaceDetectedGitRoot() ?? activeWorkspaceURL()`)에서 `git grep -n -E`로 선언 패턴 검색: `(func|class|struct|enum|protocol|extension|let|var|fun|def|function|const|type|interface)\s+word\b` 언어별. 첫 매치의 파일:라인을 연다.
- **막히는 지점**: "임의 파일을 특정 라인에서 열기" 경로가 현재 없다. 리뷰/파일 뷰는 워크스페이스의 변경/소스 파일만 렌더한다. 임의 경로 파일을 Files 뷰(code-viewer.html)로 열고 그 라인으로 스크롤+커서 이동하는 배선을 새로 만들어야 함(`renderSourceFile` 계열 + Monaco `revealLineInCenter`/`setPosition`을 code-viewer.html에 메시지로). 이게 이 작업의 실제 무게.
- Cmd+↓가 다른 곳에 안 쓰이는지 확인(현재 미바인딩으로 추정). Monaco 포커스면 JS keydown에서 `e.metaKey&&e.key==='ArrowDown'` 잡기.

## 작업 3 — diff view IntelliJ 패리티 잔여
- **사이드바 파일명 우선**: `diffSidebarRowButton`(MainWindowController+ChangesReview.swift ~1138)의 `countsStack`이 99pt 고정(+add 53 / −del 43)이라 파일명이 잘림. 스탯을 축소/부차화하고 파일명이 전부 보이게. **스모크가 `diff-stat-additions/deletions` identifier·폭(53/43)·배지를 검사**하므로 native-guard + key-input 스모크 계약도 함께 갱신(메모리 `hybrid-webview-smoke-fallback` 마지막 문단).
- **코멘트 박스를 파일뷰 박스처럼**: 파일뷰 코멘트도 네이티브 `NativeInlineReviewCommentBox`(NativeTextViews.swift, cornerRadius 6, panelBackground, kind별 타이틀/Cmd+Enter/본문). 현재 Monaco JS view-zone 박스(`renderComments` in diff-viewer.html)를 그 디자인에 맞춰 재현(라운드·kind색·타이틀+본문 레이아웃). 필요하면 JS 라이브러리 OK.
- **가운데 라인번호 (Monaco 한계)**: Monaco side-by-side는 라인번호를 각 패널 왼쪽에 둔다. IntelliJ식 가운데 공용 거터는 네이티브로 안 됨 → 라인번호 끄고(`lineNumbers:'off'`) 커스텀 중앙 거터 DOM을 그리거나, 원본 패널 라인번호를 오른쪽 정렬하는 커스텀이 필요(큼). 사용자와 수용 범위 합의 필요.
- **파랑=수정 배경 (Monaco 한계)**: Monaco diff는 추가(초록)/삭제(빨강)만. IntelliJ의 "양쪽 존재+변경 줄=파랑(#2B3A52)"은 없음 → `getLineChanges()`로 줄 분류해 커스텀 데코레이션(파랑 배경)을 직접 얹어야 함(큼).

## 작업 4 — 레이어드 설정 ("진짜 위에 겹쳐 표시")
- 현재 설정은 공유 `overlayView`(overlayMode=.settings)를 Files/Changes와 배타적으로 쓴다. 사용자는 **설정을 Files/Changes 위에 별도 레이어로 겹쳐** 띄우길 원함("cmd0/cmd1/프롬프트 다 하이브리드 JS로 가는 방향"이라 했으니 하이브리드도 고려 가능).
- 걸림돌: 설정 스모크 8개+검증자(`settingsOverlayIsConfiguredForSmokeTest` 등, MainWindowController+SmokeSupport.swift)가 전부 공유 `overlayView`/`overlaySettingsStack`/`overlaySidebarStack`을 참조 → 별도 surface로 옮기면 스모크 전체 재작성 필요.
- 참고: 클릭-닫힘 버그는 이미 수정됨(설정은 backdrop 클릭으로 안 닫힘 — `overlayBackdrop.onClick`에서 `overlayMode == .settings`면 return).

## 이번 세션에서 이미 완료·설치된 것 (재작업 금지)
워크스페이스 생명주기(US-1~8) + 회귀 스모크, Cmd+Backspace 이중전달 flake 근본 수정, git 라이브 감지 2.5초 타이머, Cmd+1 감지 git 디렉토리, 삭제 확인 다이얼로그, blur toast, 파일트리 ← 접기, 설정 클릭-닫힘, diff 리뷰 Phase 1(Monaco 깜빡 커서+F7/Shift+F7+화살표+마지막-헝크 힌트) + Phase 2(Shift+?/> 코멘트 view zone+선택 동기화+Backspace 삭제 확인) + Darcula 테마 + Shift+Tab.

## 검증 루틴
```
./scripts/build.sh                          # BUILD_EXIT=0, error: 없어야 함 (파이프|tail 금지 — exit code 가려짐)
node scripts/native-guard-smoke.mjs         # 소스 패턴 계약검사; diffViewerHtml은 files 아닌 별도 const(window.webkit forbidden 스캔 회피)
./scripts/key-input-smoke.sh                # 로그의 "key input smoke ok" 확인 (startup timeout은 동시부하 flake → 단독 재실행)
./scripts/install-app.sh                    # 설치본 갱신 후 수동 테스트
```
Monaco 변경은 스모크로 런타임 검증 불가 → native-guard 소스 계약 + 설치본 수동/프리뷰 확인. 시그니처/문자열 바꾸면 native-guard `check(...)` 정규식과 스모크 fail 문자열 함께 갱신.
