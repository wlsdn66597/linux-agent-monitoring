# Linux Agent Monitoring

Ubuntu 22.04 서버를 대상으로 **최소 권한의 다중 사용자 운영 환경**, **SSH/UFW 네트워크 보안**, **애플리케이션 5단계 부팅 검증**, **Bash 기반 상태 수집·로그 회전·cron 자동 실행**을 한 번에 재현하는 과제입니다. 보너스 문제는 제외하고 필수 요구사항만 구현했습니다.

## 전체 구성과 개발 방식

```mermaid
flowchart LR
    A[setup.sh] --> B[SSH 20022<br/>Root 로그인 차단]
    A --> C[UFW<br/>20022·15034만 허용]
    A --> D[계정·그룹·ACL]
    D --> E[agent_app.py<br/>agent-admin으로 실행]
    E --> F[0.0.0.0:15034]
    G[agent-admin cron<br/>매분] --> H[monitor.sh]
    H --> I{프로세스·포트}
    I -->|실패| J[exit 1]
    I -->|정상| K[CPU·MEM·DISK 수집]
    K --> L[/var/log/agent-app/monitor.log]
    L --> M[10MB 도달 시 회전<br/>archive 10개 유지]
```

구현은 다음 원칙으로 나눴습니다.

- `setup.sh`: 서버 상태를 요구사항대로 만드는 멱등성 설치 스크립트
- `agent_app.py`: 5단계 Boot Sequence와 15034 포트 리슨을 재현하는 최소 실행 대상
- `monitor.sh`: 프로세스·포트 실패는 종료하고, 방화벽·자원 임계값은 경고만 남기는 운영 스크립트
- `tests/test_monitor.sh`: 앱 정상 상태와 앱 종료 후 `exit 1`을 확인하는 통합 테스트
- GitHub Actions: Ubuntu 22.04에서 Bash 문법과 핵심 동작을 자동 검증

> **주의:** `setup.sh`는 UFW 기존 규칙을 초기화하고 SSH 포트를 변경합니다. 원격 운영 서버에서 바로 실행하지 말고 VM/콘솔에서 검토한 뒤 사용하세요. SSH 공개키와 별도 콘솔 접속 수단을 먼저 확보해야 합니다.

## 저장소 구조

```text
.
├── .github/workflows/ci.yml
├── agent_app.py
├── monitor.sh
├── setup.sh
└── tests/test_monitor.sh
```

## 빠른 실행

대상은 Ubuntu 22.04 LTS의 새 VM을 권장합니다.

```bash
git clone https://github.com/wlsdn66597/linux-agent-monitoring.git
cd linux-agent-monitoring
chmod +x setup.sh monitor.sh tests/test_monitor.sh
sudo CONFIRM_UFW_RESET=YES ./setup.sh
```

설치 후 앱은 systemd의 `agent-app.service`로, 모니터는 `agent-admin`의 cron으로 실행됩니다.

```bash
sudo systemctl status agent-app --no-pager
sudo journalctl -u agent-app -n 30 --no-pager
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh
sudo crontab -u agent-admin -l
sudo tail -n 5 /var/log/agent-app/monitor.log
```

환경 변수는 `/etc/profile.d/agent-app.sh`와 systemd unit에 고정합니다.

| 변수 | 값 |
|---|---|
| `AGENT_HOME` | `/home/agent-admin/agent-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys/t_secret.key` |
| `AGENT_LOG_DIR` | `/var/log/agent-app` |

## 수행 내역과 검증 명령

아래 명령의 출력은 **대상 VM에서 직접 실행해 캡처**해야 합니다. 저장소는 실행하지 않은 결과를 증거처럼 기재하지 않습니다.

### 1. SSH와 방화벽

`/etc/ssh/sshd_config.d/99-agent-app.conf`에 `Port 20022`, `PermitRootLogin no`를 두고 `sshd -t` 통과 후 서비스를 재시작합니다. UFW는 인바운드 기본 거부, 아웃바운드 허용이며 TCP 20022와 15034만 명시적으로 허용합니다.

```bash
sudo sshd -T | grep -E '^(port|permitrootlogin)'
sudo ss -ltnp | grep ':20022'
sudo ufw status numbered
```

기대 핵심: `port 20022`, `permitrootlogin no`, UFW `Status: active`, 허용 규칙 20022/tcp와 15034/tcp.

### 2. 계정·그룹·ACL

- `agent-common`: agent-admin, agent-dev, agent-test
- `agent-core`: agent-admin, agent-dev
- `upload_files`: agent-common이 읽기/쓰기, setgid와 기본 ACL로 새 파일에도 정책 상속
- `api_keys`, `/var/log/agent-app`: agent-core만 읽기/쓰기, other 권한 없음
- `monitor.sh`: owner=agent-dev, group=agent-core, mode=750

```bash
id agent-admin
id agent-dev
id agent-test
namei -l /home/agent-admin/agent-app/bin/monitor.sh
getfacl /home/agent-admin/agent-app/upload_files
getfacl /home/agent-admin/agent-app/api_keys
getfacl /var/log/agent-app
stat -c '%U %G %a %n' /home/agent-admin/agent-app/bin/monitor.sh
```

### 3. 앱 Boot Sequence와 포트

앱은 root를 거부하고, 사용자 → 환경 변수 → 필수 디렉터리/키 → 포트 가용성 → 로그 쓰기 권한의 5단계를 모두 통과해야 서버를 엽니다.

```bash
sudo journalctl -u agent-app -n 30 --no-pager
sudo ss -ltnp | grep ':15034'
curl -fsS http://127.0.0.1:15034/health
```

기대 핵심: `[1/5]`부터 `[5/5]`까지 `[OK]`, `Agent READY`, `0.0.0.0:15034` LISTEN, `{"status": "ok"}`.

### 4. monitor.sh와 cron

`pgrep -f`는 실행 명령 전체에서 앱 파일명을 찾으므로 Python 인터프리터 뒤에 붙은 파일도 식별합니다. `ss -ltnH`는 LISTEN 소켓만 확인합니다. 둘 중 하나라도 실패하면 `exit 1`이며, 방화벽 비활성 및 자원 초과는 운영 관측을 계속하기 위해 `[WARNING]`만 출력합니다.

```bash
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh
echo $?
sudo tail -n 5 /var/log/agent-app/monitor.log
sudo crontab -u agent-admin -l
before=$(sudo wc -l < /var/log/agent-app/monitor.log)
sleep 70
after=$(sudo wc -l < /var/log/agent-app/monitor.log)
printf 'before=%s after=%s\n' "$before" "$after"
```

로그 한 줄은 다음 형식입니다.

```text
[YYYY-MM-DD HH:MM:SS] PID:1234 CPU:12.3% MEM:8.4% DISK_USED:31%
```

CPU는 `/proc/stat`을 1초 간격으로 두 번 읽은 전체 jiffy 차이에서 idle 차이를 빼 계산합니다. 메모리는 `/proc/meminfo`의 `MemTotal - MemAvailable`, 디스크는 `df -P /`의 루트 파티션 사용률을 사용합니다. 고정 형식은 grep/awk 같은 기본 도구로 후속 분석하기 쉽고 시간순 장애 추적이 가능합니다.

## 평가항목별 설명

### 평가항목 1 — 필수 기능 완성도

1. **SSH 20022·Root 차단:** drop-in 설정을 생성하고 `sshd -t`로 문법을 검증한 뒤 재시작합니다.
2. **방화벽 활성화·두 포트만 허용:** UFW를 초기화한 후 deny incoming 정책과 20022/15034 규칙만 등록합니다.
3. **계정·그룹 구성:** 세 계정 모두 agent-common, admin/dev만 agent-core에 넣어 역할을 분리합니다.
4. **5단계 Boot Sequence:** 모든 선행 조건을 검사한 뒤에만 `Agent READY`와 HTTP 서버를 시작합니다.
5. **프로세스·포트 Health Check:** 둘 중 하나라도 비정상이면 에러를 출력하고 종료 코드 1을 반환합니다.
6. **지정 포맷 누적 로그:** 정상 Health Check 뒤 타임스탬프·PID·CPU·MEM·DISK를 한 줄씩 `>>` 방식으로 남깁니다.
7. **매분 자동 실행:** agent-admin의 crontab에 동일 항목을 제거 후 재등록해 중복 없이 매분 실행합니다.
8. **10MB/10개 용량 관리:** 쓰기 전 현재 파일이 10MiB 이상이면 `.1`~`.10`으로 밀고 가장 오래된 파일을 삭제합니다.

### 평가항목 2 — 구현 선택과 설명

1. **프로세스/포트 명령:** `pgrep -f`는 스크립트명 포함 명령행을 안정적으로 찾고, `ss`는 최신 Linux의 표준 소켓 조회 도구라 선택했습니다.
2. **CPU/MEM/DISK 파싱:** locale 영향을 줄이기 위해 `LC_ALL=C`와 커널 가상 파일·POSIX 형식 `df -P`를 사용합니다.
3. **소유자와 실행자 정책:** 개발자 agent-dev가 스크립트를 소유하고, agent-core의 agent-admin이 group execute로 cron 실행하며 other는 접근할 수 없습니다.
4. **로그 회전 방식:** 외부 주기 설정에 의존하지 않고 매 실행 직전 크기를 검사하므로 임계값 도달 후 다음 분에 즉시 회전합니다. 활성 로그 외 보관본은 최대 10개입니다.

### 평가항목 3 — 보안·운영 이해

1. **SSH 보안 효과:** 비표준 포트는 무차별 스캔 노이즈를 줄이고 Root 원격 차단은 단일 고권한 계정의 직접 탈취 경로를 없앱니다. 포트 변경만으로 인증 보안을 대체하지는 않습니다.
2. **최소 권한:** 테스트 사용자는 공유 업로드에는 참여하지만 키와 운영 로그는 볼 수 없고, core 역할만 민감 데이터에 접근합니다.
3. **실패와 경고 분리:** 앱/포트 부재는 서비스 불능이므로 실패 처리하고, 방화벽 상태 조회 실패나 순간 자원 초과는 관측 데이터가 끊기지 않도록 경고 후 계속합니다.
4. **리다이렉션:** `>`는 파일을 비우고 새로 쓰며 `>>`는 끝에 추가합니다. 시계열 로그는 이전 기록 보존이 핵심이므로 `>>`가 필요합니다.

### 평가항목 4 — 장애 대응과 확장

1. **Nginx로 대상 변경:** `PROCESS_PATTERN`, `AGENT_PORT`를 nginx 값으로 바꾸고, 필요하면 HTTP 상태 코드 검사와 access/error log 경로, worker 계정을 추가 확인합니다.
2. **프로세스는 살고 포트는 닫힌 경우:** `ss` → `journalctl` → 환경 변수/설정 → 포트 충돌 → 권한/SELinux·AppArmor → localhost 직접 요청 순으로 확인합니다.
3. **로그 급증·디스크 위험:** 단기에는 원인 로그 레벨 조정, 강제 회전, 오래된 안전한 파일 이동으로 공간을 확보합니다. 중장기에는 보존 기간·압축·중앙 로그 수집·디스크 알림·용량 계획을 적용합니다.

## 필수 증거 자료 체크리스트

- [ ] `sshd -T`의 20022와 Root 차단
- [ ] `ss`의 sshd 20022 LISTEN
- [ ] `ufw status`의 active 및 허용 포트 2개
- [ ] 세 계정의 `id`와 두 그룹 구성
- [ ] 디렉터리 `ls -ld`, `getfacl`, monitor.sh의 `750`
- [ ] Boot Sequence 5개 `[OK]`와 `Agent READY`
- [ ] monitor.sh 정상 출력 및 앱/포트 장애 시 `exit 1`
- [ ] monitor.log 최근 행과 지정 포맷
- [ ] agent-admin crontab과 1분 뒤 로그 행 증가
- [ ] 10MiB 테스트 파일로 `.1` 회전 및 최대 `.10` 유지

## 테스트

로컬 Linux 또는 CI에서 다음을 실행합니다.

```bash
bash -n monitor.sh setup.sh tests/test_monitor.sh
bash tests/test_monitor.sh
```

통합 테스트는 임시 디렉터리에서 앱을 띄워 `Agent READY`, 포트 리슨, 로그 정규식, 앱 종료 뒤 monitor의 실패 반환을 확인합니다. 호스트의 SSH/UFW/계정 설정은 권한과 접속 단절 위험 때문에 CI에서 변경하지 않고 대상 VM에서 위 체크리스트로 검증합니다.
