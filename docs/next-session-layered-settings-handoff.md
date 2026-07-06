# 핸드오프 — Task 5: 레이어드 설정 ("진짜 위에 겹쳐 표시")

## 현재 상태 (2026-07-06 세션)
**Design I(모달-오버-스냅샷)를 구현·설치했다.** `openSettings()`가 Files/Changes가 열려 있으면 그 오버레이를 `bitmapImageRepForCachingDisplay`로 스냅샷해 `settingsUnderlayImageView`(백드롭 아래)에 깔고, 설정 모달을 그 위에 띄운다. 닫으면(`closeOverlayAction`→`dismissSettingsLayer`) `settingsReturnMode`로 Files/Changes에 복귀. 기존 설정 스모크 12개는 `showOverlay(.settings)` 직접 호출이라 **무변경으로 green 유지**, 신규 `settingsLayersOverReviewForSmokeTest`로 레이어링 검증. native-guard "settings float as a layer over the review panel and return on close" 계약 추가.

**Design I 한계**: Changes(Monaco/WKWebView)는 out-of-process 렌더라 `cacheDisplay` 스냅샷에서 Monaco 영역이 비어 보일 수 있다(네이티브 사이드바/크롬은 정상, 중앙은 모달이 덮음). Files(네이티브 코드 페인)는 완전 정상. 배경이 정적 스냅샷이라 비상호작용.

## 아래는 Design G (진짜 별도 인터랙티브 레이어) — 스냅샷으로 부족할 때의 더 깊은 대안

## 목표
설정 패널을 Files/Changes **위에 별도 레이어로 겹쳐** 띄운다. 현재는 열면 Files/Changes를 대체(mode 전환)하지만, 사용자는 아래에 Files/Changes가 보이는 상태로 설정이 그 위에 뜨길 원한다("진짜 위에 겹쳐").

## 현재 아키텍처 (왜 큰 작업인가)
- 설정은 공유 `overlayView`를 `overlayMode == .settings`로 **배타적** 사용한다. `setSettingsContentVisible(true)`가 `overlayDiffSplitView`를 숨기고 `overlaySettingsScrollView`를 보인다 → Changes와 상호배타.
- 설정 콘텐츠: `overlaySettingsScrollView` + `overlaySettingsStack`(콘텐츠), `overlaySidebarStack`(사이드바, Files/Changes와 **공유**), `overlayContentView` 내부.
- 모달 지오메트리는 `compactOverlayModeActive`(quickOpen과 공유)가 구동 → 별도 레이어는 자체 사이징 필요.

## 결합된 스모크/검증자 (재작성 대상, `MainWindowController+SmokeSupport.swift`)
12개 함수가 공유 오버레이를 참조: `settingsTextForSmokeTest`, `settingsOverlayIsConfiguredForSmokeTest`, `settingsOverlayMatchesPreferencesDesignForSmokeTest`, `settingsOverlayLayoutDiagnosticsForSmokeTest`, `selectSettingsCategoryForSmokeTest`, `settingsSidebarSelectionWorksForSmokeTest`, `settingsPromptEditorsWrapForSmokeTest`, `settingsOverlayHasNoClippedControlsForSmokeTest`, `settingsPromptEditorCountForSmokeTest`, `settingsPromptTextForSmokeTest`, `settingsPromptIsEditableForSmokeTest`, `settingsPromptSavedStatusForSmokeTest`.
- 주요 참조: `overlayMode == .settings`(10곳/6파일), `overlayDiffSplitView.isHidden`, `overlaySettingsScrollView`, `overlaySettingsStack`, `overlaySidebarStack`, `collectVisibleText(in: overlayView)`, `overlayView.frame` 모달 지오메트리, `overlaySidebarWidthConstraint == settingsSidebarWidth`.
- native-guard: `settingsOverlayIsConfiguredForSmokeTest`/`settingsSidebarSelectionWorksForSmokeTest`/settings design 계약(라인 381-382 등)도 함께 갱신.

## 권장 구현 (AppKit 별도 레이어)
1. **새 surface**: `settingsLayerView`(컨테이너) + `settingsBackdrop`(딤/클릭-닫힘) + `settingsCardView`(중앙 모달 카드). `overlayView` **위** z-order로 `rootView`에 addSubview. 자체 사이징(중앙 정렬, root − 40 이내 — 기존 `hasModalGeometry` 계약 재사용).
2. **콘텐츠 이동**: 설정 사이드바 + `overlaySettingsScrollView`/`overlaySettingsStack`를 `settingsCardView`로 **재부모화**하거나, 전용 스택(`settingsLayerSidebarStack`, `settingsLayerContentStack`)을 신설. 재부모화가 스모크 변경 최소.
3. **`openSettings()`**: `overlayMode`를 **건드리지 않고** `settingsLayerView.isHidden=false` + fade-in. Files/Changes는 그대로 아래 유지. `settingsLayerVisible` 플래그 도입.
4. **닫기**: Esc + backdrop 클릭 → `settingsLayerView.isHidden=true`, Files/Changes 포커스 복귀. `handleShortcut`의 Esc 분기에서 `settingsLayerVisible`를 먼저 처리.
5. **`overlayMode == .settings` 제거**: `.settings` case를 `settingsLayerVisible`로 대체(또는 enum은 두되 레이어 가시성으로 분기). `populateOverlay`의 settings 분기 정리.
6. **스모크/native-guard 재작성**: 위 12개 함수가 `settingsLayerView`/새 스택을 검사하도록. `overlayDiffSplitView.isHidden` 기대 제거(설정이 더 이상 diff를 숨기지 않음 — 아래 유지가 목표). 모달 지오메트리 검사는 `settingsCardView.frame` 기준으로.

## 검증
- `./scripts/build.sh`(파이프 금지), `node scripts/native-guard-smoke.mjs`, `./scripts/key-input-smoke.sh`("key input smoke ok"), `./scripts/install-app.sh`.
- 설정 스모크는 **런타임 GUI** — 레이어 지오메트리/포커스/닫힘을 실제로 검증. CPU 여유 있을 때 단독 실행 권장(동시부하 시 startup-timeout flake).
- 모달 겹침은 스모크로 픽셀 검증 불가 → 설치본 수동 확인 필요.

## 주의
- `git add`는 대상 파일만 명시(conductor 워킹트리에 병렬 변경 유입).
- 하이브리드 방향: 사용자는 "cmd0/cmd1/프롬프트 다 하이브리드 JS로 가는 방향"이라 했으므로, 장기적으로 설정도 webview 레이어로 갈 수 있음 — 단, 그건 더 큰 작업(별도 스코프).
