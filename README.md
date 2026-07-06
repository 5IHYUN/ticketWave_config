# ⚙️ Team5 Ticket Config (team5-ticket-config)

> **GitOps & Kubernetes Configuration Repository**  
> ArgoCD 및 Kustomize 기반으로 EKS 클러스터에 배포되는 애플리케이션 Manifest, System Add-on, 오토스케일링 및 관측성 리소스를 선언적으로 관리하는 SSoT(Single Source of Truth) 저장소입니다.

애플리케이션 소스 코드는 [team5-ticket-app](https://github.com/CLD-05/team5-ticket-app)에서 관리하고, AWS 인프라는 [team5-ticket-infra](https://github.com/CLD-05/team5-ticket-infra)에서 Terraform으로 관리합니다. 이 저장소는 두 저장소 사이에서 실제 Kubernetes 배포 상태를 정의하는 역할을 담당합니다.

즉, app repository에서 빌드된 Docker image tag가 이 저장소의 Kustomize overlay에 반영되면, ArgoCD가 변경 사항을 감지하여 EKS 클러스터에 배포합니다.

---

## 📋 1. 개요 및 설계 목표

이 저장소는 Ticket Wave 플랫폼의 Kubernetes Manifest 및 ArgoCD Application을 관리하는 GitOps Config 저장소입니다.

- **dev/prod 환경별 Kubernetes Manifest 관리**: Kustomize overlay를 활용한 환경 격리 및 배포 사양 커스텀.
- **ArgoCD 기반 GitOps 배포 구조 구성**: 선언적 매니페스트 동기화 및 자동 복구(Self-Healing) 제공.
- **Web API Pod와 Booking Worker Pod 분리 배포**: 대용량 트래픽의 동기 처리와 비동기 쓰기 계층의 물리적 분리.
- **Gateway API 기반 ALB 라우팅 구성**: Ingress 대신 LBC v2.13+ 기반 최신 Gateway API (`GatewayClass`, `Gateway`, `HTTPRoute`) 도입.
- **HPA/KEDA 기반 다중 오토스케일링**: API Pod는 HPA(CPU)가, Worker Pod는 KEDA(SQS 대기 메시지 수)가 동적으로 제어.
- **External Secrets Operator 기반 Secret 동기화**: AWS Secrets Manager의 민감 정보를 EKS Secret(`ticket-app-secret`)으로 실시간 주입.
- **관측성 및 알림 연동**: Prometheus/Grafana/YACE를 통한 모니터링 및 SLO 위반 시 Slack 알림 발송.
- **배포 경계 분리**: system add-ons와 application manifest 배포 파이프라인의 명확한 책무 분리.

---

## 🏗️ 2. GitOps 아키텍처

```text
app repo (GitHub Actions)
  │
  ├─► Docker build / ECR push
  └─► image tag update (Kustomize Overlay)
        │
        ▼
config repo (GitHub)
  │
  ▼
ArgoCD (EKS Cluster)
  │
  ├─► system-addons
  │     - AWS Load Balancer Controller (Gateway API)
  │     - External Secrets Operator (ESO)
  │     - ExternalDNS (Route53 레코드 관리)
  │     - KEDA (Worker 오토스케일링)
  │     - kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
  │     - YACE (CloudWatch SQS 메트릭 수집 Exporter)
  │     - Cluster Autoscaler & Metrics Server
  │     - StorageClass (EBS GP3 동적 볼륨 프로비저닝)
  │
  └─► ticket application (apps/ticket-app)
        - Gateway / HTTPRoute (L7 ALB 라우팅)
        - ticket-service (Web API Pods - HPA CPU 50%)
        - booking-worker (Worker Pods - KEDA SQS Metric)
        - ServiceMonitor & PrometheusRule (SLO/SLI)
```

---

## 📂 3. 저장소 구조 (Repository Structure)

```text
team5-ticket-config/
├── argocd/                         # ArgoCD Project 및 Application 정의
│   ├── project.yaml
│   ├── application-dev.yaml
│   ├── application-prod.yaml
│   ├── application-addons-dev.yaml
│   ├── application-addons-prod.yaml
│   └── application-monitoring.yaml
│
├── apps/
│   └── ticket-app/                 # 애플리케이션 Kustomize Manifest
│       ├── base/
│       │   ├── deployment.yaml     # Web API Pod Deployment
│       │   ├── service.yaml        # ClusterIP Service
│       │   ├── serviceaccount.yaml # ticket-service SA
│       │   ├── gatewayclass.yaml   # AWS ALB GatewayClass
│       │   ├── gateway.yaml        # Gateway API
│       │   ├── httproute.yaml      # HTTPRoute 라우팅 Rules
│       │   └── loadbalancerconfiguration.yaml
│       └── overlays/
│           ├── dev/                # dev 환경 패치
│           │   ├── kustomization.yaml
│           │   ├── deployment-patch.yaml
│           │   ├── deployment-booking-worker.yaml
│           │   ├── service-booking-worker.yaml
│           │   ├── externalsecret.yaml
│           │   ├── hpa.yaml        # min 1 / max 5 (CPU 50%)
│           │   ├── scaledobject-booking-worker.yaml # KEDA SQS (dev-queue)
│           │   ├── servicemonitor-booking.yaml
│           │   └── gateway-class-patch.yaml
│           └── prod/               # prod 운영 환경 패치
│               ├── kustomization.yaml
│               ├── deployment-patch.yaml
│               ├── deployment-booking-worker.yaml
│               ├── service-booking-worker.yaml
│               ├── externalsecret.yaml
│               ├── hpa.yaml        # min 3 / max 8 (CPU 50%)
│               ├── scaledobject-booking-worker.yaml # KEDA SQS FIFO (prod-queue.fifo)
│               ├── servicemonitor-booking.yaml
│               ├── httproute-patch.yaml   # Route53 커스텀 도메인 라우팅
│               ├── gateway-waf-patch.yaml # AWS WAF WebACL 연결
│               ├── gateway-class-patch.yaml
│               └── service-patch.yaml
│
├── system-addons/                  # Kubernetes System Add-on Manifests
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── storageclass.yaml
│   │   ├── external-secrets.yaml
│   │   ├── external-dns.yaml
│   │   ├── aws-load-balancer-controller.yaml
│   │   ├── zipkin.yaml
│   │   └── clustersecretstore.yaml
│   └── overlays/
│       ├── dev/
│       └── prod/
│
└── infra/
    └── monitoring/                 # Grafana Dashboard ConfigMaps
        ├── kustomization.yaml
        ├── team5-overview.json     # 시스템 전체 개요
        ├── team5-sync.json         # SQS 및 KEDA 동기화 상태
        ├── team5-system.json       # EKS Node / Pod 리소스 사용량
        └── team5-unified.json      # 통합 관측성 & SLO 모니터링
```

| 디렉터리 경로 | 역할 및 설명 |
|---|---|
| `argocd` | ArgoCD Project와 Environment별 Application 정의 |
| `apps/ticket-app/base` | dev/prod 공통 기본 애플리케이션 매니페스트 |
| `apps/ticket-app/overlays/dev` | 개발 환경 용 리소스 한계/HPA/KEDA/시크릿 패치 |
| `apps/ticket-app/overlays/prod` | 운영 환경 용 고가용성/HPA/WAF/도메인 패치 |
| `system-addons/base` | 클러스터 기본 애드온 (LBC, ESO, ExternalDNS 등) |
| `system-addons/overlays/dev` | 개발 환경 활성화 애드온 (KEDA, YACE, Metrics Server 등) |
| `system-addons/overlays/prod` | 운영 환경 활성화 애드온 (+ Cluster Autoscaler, KPS 등) |
| `infra/monitoring` | Grafana Dashboard JSON 파일을 K8s ConfigMap으로 자동 배포 |

---

## ⚙️ 4. 환경별 설정 비교 (dev vs prod)

| 구분 | dev 환경 | prod 환경 |
|---|---|---|
| **Kustomize Overlay** | `apps/ticket-app/overlays/dev` | `apps/ticket-app/overlays/prod` |
| **ECR Image** | `team5-dev-app` (Mutable tag) | `team5-prod-app` (Immutable tag) |
| **Spring Profile** | `dev` | `prod` |
| **Secret Source** | AWS Secrets Manager `team5/dev/ticket-app` | AWS Secrets Manager `team5/prod/ticket-app` |
| **SQS Queue Metric** | `team5-dev-booking-queue` (Standard) | `team5-prod-booking-queue.fifo` (FIFO) |
| **Web API HPA** | Min 1 / Max 5 (CPU 50%) | Min 3 / Max 8 (CPU 50%) |
| **Worker KEDA** | Min 1 / Max 20 (Threshold: 5) | Min 1 / Max 20 (Threshold: 5) |
| **Ingress / DNS** | ALB DNS 직접 접근 | Route53 (`team5.cloud-infra.shop`) |
| **보안 장치** | 기본 보안 규칙 적용 | AWS WAF 연결, Read Replica 분리, CDN 적용 |

---

## 🏗️ 5. Application Manifests 상세

### 5.1 Gateway API
기존의 Ingress 대신 최신의 **Gateway API** 표준 스펙을 도입하여 L7 ALB 프로비저닝 및 유연한 경로 기반 라우팅을 수행합니다.
- **GatewayClass**: AWS Load Balancer Controller를 컨트롤러(`group.association.gateway.k8s.aws/alb`)로 연결.
- **Gateway**: 실제로 생성될 AWS Application Load Balancer(ALB)의 scheme, subnets, tags 등을 주입.
- **HTTPRoute**: `/` 및 `/api` 경로 트래픽을 EKS 내부의 `ticket-service` ClusterIP 서비스로 매핑.

### 5.2 Web API Pod (`ticket-service`)
사용자 요청(대기열 진입, 좌석 선점 등)을 동기 처리하는 API Pod 그룹입니다.
- **Container Port**: `8080` (Actuator 프로브 활성화: `/actuator/health/liveness`, `readiness`).
- **Resource Limits**: dev/prod 환경 사양에 맞는 CPU/Memory Request 및 Limit 정의.
- **Bypass Mode**: 부하 테스트 목적의 대기열 우회 옵션 (`QUEUE_TOKEN_BYPASS=false`) 환경변수 제공.

### 5.3 Booking Worker Pod (`booking-worker`)
SQS 큐의 예매 요청 메시지를 컨슘하여 DB에 저장하는 비동기 프로세서 그룹입니다.
- API Pod와 동일한 Docker 이미지를 공유하되, 환경변수 `SPRING_PROFILES_ACTIVE=prod,worker`를 추가 주입하여 Worker 프로세스(Message Listener)만 기동되도록 책무를 분리했습니다.
- 외부 트래픽에 노출되지 않으며 ClusterIP Service를 바인딩하지 않습니다.

---

## 📈 6. 오토스케일링 (Autoscaling)

### 6.1 Web API HPA (Horizontal Pod Autoscaler)
CPU 사용률이 **50%**를 초과할 경우 API Pod를 신속하게 확장합니다. 스케일아웃 시 과도한 급증과 스케일다운 시의 급격한 축소로 인한 진동 현상을 방지하기 위해 Stabilization Window를 튜닝했습니다.
- **Stabilization Window**: Scale-up 60초 / Scale-down 300초
- **Scale-up Policy**: 60초당 최대 100% 또는 +4 Pods 확장

### 6.2 Worker KEDA (Kubernetes Event-driven Autoscaling)
SQS의 대기 중인 메시지 수에 반응하여 Worker Pod를 탄력적으로 확장합니다. YACE가 CloudWatch에서 SQS 지표를 수집하고, Prometheus가 이를 적재하면 KEDA가 PromQL 쿼리로 조회하는 파이프라인을 탑재하였습니다.
```text
CloudWatch SQS Metrics ──► YACE ──► Prometheus ──► KEDA ScaledObject ──► booking-worker 스케일링
```
- **KEDA 설정**:
  - `minReplicaCount`: 1 (메시지 처리 대기시간 최소화를 위한 Prewarm 확보)
  - `maxReplicaCount`: 20
  - `metricType`: `AverageValue` (Threshold: SQS 대기 메시지 5개당 Worker 1대 추가)
- **ArgoCD 동기화 유지 (`ignoreDifferences`)**: KEDA가 replicas를 동적으로 변경하므로 ArgoCD가 drift로 판단해 덮어쓰지 않도록 `ignoreDifferences` 예외 필터를 argocd application 매니페스트에 추가하였습니다.

---

## 🛡️ 7. Secrets & Security

인프라의 자격 증명과 DB 패스워드 등 민감 정보는 소스코드에 평문 노출하지 않고, **External Secrets Operator(ESO)**가 AWS Secrets Manager로부터 안전하게 가져와 Kubernetes Secret(`ticket-app-secret`)으로 동기화합니다.

### 동기화 항목 상세
- `SPRING_DATASOURCE_URL` & `SPRING_DATASOURCE_USERNAME` & `SPRING_DATASOURCE_PASSWORD`
- `SPRING_DATA_REDIS_HOST` & `SPRING_DATA_REDIS_PORT`
- `AWS_SQS_BOOKING_QUEUE_URL` & `AWS_SQS_BOOKING_QUEUE_ARN`
- `JWT_SECRET`
- `SPRING_DATASOURCE_REPLICA_URL` (prod 전용)
- `APP_S3_CDN_BASE_URL` (prod 전용)

---

## 📊 8. 관측성 (Observability)

### 8.1 Application metrics
API/Worker Pod는 Spring Boot Actuator 메트릭을 노출합니다.  
`servicemonitor-booking.yaml`은 Prometheus가 API/Worker의 Actuator Prometheus endpoint(`/actuator/prometheus`)를 15초 주기로 scrape하도록 구성합니다.

### 8.2 SQS metrics
YACE는 CloudWatch의 SQS metric을 Prometheus metric으로 변환합니다.
- 수집 대상: `ApproximateNumberOfMessagesVisible`, `ApproximateAgeOfOldestMessage` 등

### 8.3 Grafana dashboards
`infra/monitoring`은 Grafana dashboard JSON 파일을 ConfigMap으로 생성하여 sidecar에 의해 대시보드를 자동 로드합니다.
- `team5-overview.json`: 전체 시스템 가시성 대시보드
- `team5-sync.json`: SQS 및 KEDA 동적 스케일링 상태 추적
- `team5-system.json`: CPU, Memory, Network 등 리소스 모니터링
- `team5-unified.json`: SLO 성공률 및 에러 버짓 누적량 모니터링

---

## 🚀 9. CI/CD 파이프라인 연동

### 9.1 dev 배포 흐름
```text
app repo push ──► GitHub Actions Build ──► ECR Push ──► config repo dev 이미지 태그 direct push ──► ArgoCD Auto Sync (EKS 배포)
```

### 9.2 prod 승격 (Promotion) 흐름
```text
dev 검증 완료 ──► prod promotion workflow ──► prod ECR로 Re-tagging/Push ──► config repo prod 이미지 태그 변경 PR 오픈 ──► 관리자 검토 및 Merge ──► ArgoCD Sync (EKS 배포)
```
- **태그 일관성**: Git Commit SHA 해시값을 고유 태그(`dev-{SHA}`, `prod-{SHA}`)로 사용해 이미지의 빌드 출처 무결성을 보장합니다.

---

## 🛠️ 10. 운영 가이드라인 (Operations)

운영 시 아래 항목을 주기적으로 확인하고 대응합니다.

### 10.1 ArgoCD 상태 점검
- ArgoCD Web UI에서 `ticket-app-dev` 및 `ticket-app-prod` 애플리케이션의 Healthy/Synced 상태 확인.
- HPA 및 KEDA의 Pod 수 변동이 ArgoCD의 OutOfSync를 일으키지 않는지 체크.

### 10.2 애플리케이션 상태 점검
- `ticket-service` 및 `booking-worker` Pod의 `CrashLoopBackOff` 발생 유무 및 Liveness/Readiness 프로브 통과 여부 검토.
- `ticket-app-secret`이 Secrets Manager로부터 정상적으로 동기화되었는지 (`kubectl get secret ticket-app-secret -n ticketing`) 확인.

### 10.3 오토스케일링 및 메트릭 수집 점검
- `kubectl get hpa` 및 `kubectl get scaledobject`로 목표 타겟 지표 도달 여부 확인.
- CloudWatch의 SQS 지표가 YACE Exporter를 통해 Prometheus로 정상 수집되고 있는지 확인.

### 10.4 트래픽 및 DNS 연동 점검
- Route53 레코드가 ExternalDNS에 의해 올바른 ALB 주소로 매핑되었는지 확인.
- Prod 환경 Gateway에 적용된 AWS WAF WebACL 작동 여부 및 CloudWatch 로그 분석.
