# cmux 워크스페이스 개념 적용 플랜

> 작성일: 2026-07-01 · 목표: momenterm 워크스페이스를 cmux 수준의 "살아있는 에이전트 작업 단위"로 확장

## 배경

cmux(manaflow-ai/cmux)는 momenterm과 거의 동일한 컨셉(Swift/AppKit + libghostty, AI 코딩 에이전트용 터미널)이다.
momenterm은 워크스페이스의 *구조*는 이미 갖췄다:
- `Workspace(path, name, color, iconName, branchName)`, `addWorkspaceIfNeeded`, `openWorkspace`
- Cmd+N → git linked worktree(`momenterm/linked-{token}`)
- 워크스페이스별 터미널 스코프(`TerminalTab.workspacePath`, `terminalTabs(in:)`)
- 좌측 rail UI, UserDefaults 영속화(최대 40개)
- `workspaceAgentAlertPaths`(에이전트 알림 경로 집합 — 부분 구현)

cmux가 앞서는 건 각 워크스페이스를 **rich 상태 + 에이전트 알림 + 완전한 restore + 스크립트 제어**로 다루는 부분.

## 설계 원칙

1. **기존 뼈대 위 확장** — `Workspace` 모델·rail·영속화를 재사용, 필드/렌더만 확장.
2. **별도 컴포넌트로 분리** — 새 기능은 `AgentNotificationCenter`, `WorkspaceStatusProvider`,
   `MomentermSocketServer` 등 독립 타입으로. MainWindowController(God object)를 키우지 않고,
   진행 중인 도메인 분리 리팩토링 방향과 일치시킨다.
3. **회귀 스모크 필수** — 각 축·단계마다 순수 로직을 격리 스모크로 보호(xctest 없음 → swiftc 격리).

## 4개 축

### 축 1 · 에이전트 알림 기반 (토대)
다른 축(사이드바 알림 표시, CLI notify)의 기반이 되므로 먼저.
- **OSC 시퀀스 파싱**: 터미널 출력 스트림에서 OSC 9(진행/알림)·777(notify)·99(데스크톱 알림) 감지.
  기존 bell 감지(`terminalBellNotificationObserver`)를 확장. 파서는 `NativeAnsiRenderer` 또는 PTY 데이터 훅에.
- **모델**: `AgentNotification { workspacePath, terminalId, text, timestamp, unread }`, `AgentNotificationCenter`(수집·미읽음 관리).
- 단계:
  - 1a. OSC 파서 — 순수 로직(바이트 → 알림 이벤트). **격리 스모크**: 다양한 OSC 시퀀스 → 텍스트 추출.
  - 1b. PTY 데이터 → 파서 → workspace/terminal 연결.
  - 1c. pane 파란 링(대기 시각화) + rail 하이라이트.
  - 1d. Cmd+Shift+U → 최근 unread 점프.

### 축 2 · Rich 워크스페이스 사이드바
- **모델 확장**: `Workspace`에 `prNumber, prState, listeningPorts, lastNotification` 추가(+저장/복원 마이그레이션).
- **감지 (비동기·캐시, 별도 `WorkspaceStatusProvider`)**:
  - PR: `gh pr view --json number,state,...`(branch 기준).
  - ports: `lsof -nP -iTCP -sTCP:LISTEN` 파싱(워크스페이스 프로세스 스코프).
  - notification: 축 1에서.
- **rail UI 확장**: 각 워크스페이스 버튼에 branch + PR 배지 + 포트 + 최신 알림.
- 단계:
  - 2a. 모델 확장 + 영속화 마이그레이션.
  - 2b. PR 조회(gh) + 캐시. **격리 스모크**: PR JSON 파싱.
  - 2c. ports 조회. **격리 스모크**: lsof 출력 파싱.
  - 2d. rail 렌더 확장.

### 축 3 · Session restore 강화
- 현재: 터미널 탭(tmux) 복구. 갭: pane split 레이아웃, 스크롤백.
- **선행: Task #13(tmux detach 수정)** — `NativePtySession.detach()`가 프로세스를 SIGKILL하는 버그를
  "핸들만 닫고 프로세스 유지"로 고쳐야 Cmd+Q 후 재실행 시 tmux attach 복구가 성립.
- 단계:
  - 3a. detach 수정(프로세스 유지) — Task #13. **격리 스모크**: spawn→detach→프로세스 생존, →attach 복구.
  - 3b. pane split 레이아웃 저장/복원(탭 내 분할 구조 직렬화). **격리 스모크**: 레이아웃 직렬화/역직렬화.
  - 3c. 스크롤백 저장/복원(best effort).

### 축 4 · CLI / socket API
- **Unix domain socket 서버**(앱 내) + **CLI 바이너리**(`momenterm` 또는 `momenterm-cli`).
- **명령**: workspace 생성/전환, tab 생성, keystroke 전송, `notify`(에이전트 훅용 — cmux notify 대응).
- 단계:
  - 4a. socket 서버 + 명령 프로토콜(JSON 라인). **격리 스모크**: 프로토콜 인코딩/디코딩.
  - 4b. CLI 바이너리(socket 클라이언트) — 새 SwiftPM executable 타겟.
  - 4c. 명령 구현(workspace/tab/keystroke/notify).
  - 4d. 에이전트 훅 설정 가이드(Claude Code 등).

## 순서 / 의존성

```
축1(알림 토대) ──► 축2(사이드바: 알림 표시)
     └──────────► 축4(CLI notify)
Task#13(detach) ─► 축3(restore)
축2, 축3, 축4는 축1 이후 병렬 가능
```

권장 시작: **축 1 (에이전트 알림 토대)** — 가장 많은 후속이 여기에 의존하고, OSC 파서는 순수 로직이라
격리 스모크로 안전하게 시작 가능.

## 리팩토링과의 관계
- 모든 신규 로직은 별도 파일/타입으로 → God object 비대화 방지, 도메인 분리 리팩토링과 정합.
- 워크스페이스 관련 상태가 많으므로, 향후 `WorkspaceController` 추출(재설계 Step C)의 자연스러운 후보.

## 진행 상태
- [x] 축 1 · 에이전트 알림 — OSC 9/99/777 파서(`AgentNotification.swift`) + `processTerminalOutput` 연결(감지→workspace dot+macOS 알림, `agent-notification-smoke` 9케이스 green). 1c pane 파란 링(`agentAlertSessionIds` + `applyTerminalPaneSelectionStyles` accent 2px 링, 활성화 시 해제) + 1d Cmd+Shift+U unread 점프(`AgentAlertNavigator` 순수 로직 + `agent-alert-nav-smoke` 10케이스 green) 완료.
- [ ] 축 2 · Rich 사이드바 (모델 확장 → PR → ports → rail)
- [ ] 축 3 · Session restore (Task#13 detach → pane 레이아웃 → 스크롤백)
- [ ] 축 4 · CLI/socket (서버 → CLI → 명령 → 훅 가이드)
