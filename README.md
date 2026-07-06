# ⚙️ Team5 Ticket Config (team5-ticket-config)

> **GitOps & Kubernetes Configuration Repository**  
> ArgoCD 및 Kustomize 기반으로 EKS 클러스터에 배포되는 애플리케이션 Manifest, System Add-on, 오토스케일링 및 관측성 리소스를 선언적으로 관리하는 SSoT(Single Source of Truth) 저장소입니다.

---

## 📋 1. 개요 및 설계 목표

이 저장소는 Ticket Wave 플랫폼의 Kubernetes Manifest 및 ArgoCD Application을 관리하는 GitOps Config 저장소입니다.

- **GitOps 배포 자동화**: `team5-ticket-app`에서 빌드된 Docker 이미지 태그가 Kustomize overlay에 반영되면 ArgoCD가 EKS에 자동 Sync.
- **워크로드 분리 배포**: `ticket-service` (Web API Pod)와 `booking-worker` (Booking Worker Pod)를 물리적으로 분리 배포.
- **다중 오토스케일링**: Web API Pod(CPU 기반 HPA)와 Booking Worker Pod(SQS 적체량 기반 KEDA)를 독립 확장.
- **보안 & Secret 동기화**: AWS Secrets Manager의 민감 정보를 External Secrets Operator(ESO)로 K8s Secret(`ticket-app-secret`)으로 동기화.
- **Gateway API 도입**: Ingress 대신 AWS Load Balancer Controller 기반 최신 Gateway API (`GatewayClass`, `Gateway`, `HTTPRoute`) 구축.

---

## 🏗️ 2. GitOps 아키텍처

```text
app repo (GitHub Actions)
  │
  ├─► ECR Image Build & Push
  └─► config repo image tag update (Kustomize Overlay)
        │
        ▼
ArgoCD (EKS Cluster)
  │
  ├─► system-addons
  │     - AWS Load Balancer Controller (Gateway API)
  │     - External Secrets Operator (ESO)
  │     - ExternalDNS (Route53 연동)
  │     - KEDA (Worker 오토스케일링)
  │     - kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
  │     - YACE (CloudWatch SQS Exporter)
  │     - Cluster Autoscaler & Metrics Server
  │
  └─► ticket application (apps/ticket-app)
        - Gateway / HTTPRoute (ALB L7 Routing)
        - ticket-service (Web API Pod - HPA CPU 50%)
        - booking-worker (Worker Pod - KEDA SQS Metric)
        - ServiceMonitor & PrometheusRule (SLO/SLI)
```

---

## 📂 3. 디렉터리 구조

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
│       │   ├── gatewayclass.yaml   # AWS ALB GatewayClass
│       │   ├── gateway.yaml        # Gateway API
│       │   ├── httproute.yaml      # HTTPRoute 라우팅 Rules
│       │   └── loadbalancerconfiguration.yaml
│       └── overlays/
│           ├── dev/                # dev 환경 패치
│           │   ├── kustomization.yaml
│           │   ├── deployment-booking-worker.yaml
│           │   ├── hpa.yaml        # min 1 / max 5 (CPU 50%)
│           │   ├── scaledobject-booking-worker.yaml # KEDA SQS (dev-queue)
│           │   └── externalsecret.yaml
│           └── prod/               # prod 운영 환경 패치
│               ├── kustomization.yaml
│               ├── deployment-booking-worker.yaml
│               ├── hpa.yaml        # min 3 / max 8 (CPU 50%)
│               ├── scaledobject-booking-worker.yaml # KEDA SQS FIFO (prod-queue.fifo)
│               ├── gateway-waf-patch.yaml # AWS WAF WebACL 연결
│               ├── httproute-patch.yaml   # Route53 커스텀 도메인 라우팅
│               └── externalsecret.yaml
│
├── system-addons/                  # Kubernetes System Add-on Manifests
│   ├── base/
│   └── overlays/ (dev / prod)
│
└── infra/
    └── monitoring/                 # Grafana Dashboard ConfigMaps
        ├── kustomization.yaml
        ├── team5-overview.json     # 시스템 전체 개요
        ├── team5-sync.json         # SQS 및 KEDA 동기화 상태
        ├── team5-system.json       # EKS Node / Pod 리소스 사용량
        └── team5-unified.json      # 통합 관측성 & SLO 모니터링
```

---

## ⚙️ 4. 환경별 설정 비교 (dev vs prod)

| 구분 | dev 환경 | prod 환경 |
|---|---|---|
| **Kustomize Overlay** | `apps/ticket-app/overlays/dev` | `apps/ticket-app/overlays/prod` |
| **ECR Image** | `team5-dev-app` (Mutable) | `team5-prod-app` (Immutable) |
| **Spring Profile** | `dev` | `prod` |
| **Secret Source** | AWS Secrets Manager `team5/dev/ticket-app` | AWS Secrets Manager `team5/prod/ticket-app` |
| **SQS Queue Metric** | `team5-dev-booking-queue` (Standard) | `team5-prod-booking-queue.fifo` (FIFO) |
| **Web API HPA** | Min 1 / Max 5 (CPU 50%) | Min 3 / Max 8 (CPU 50%) |
| **Worker KEDA** | Min 1 / Max 20 (TargetValue 5) | Min 1 / Max 20 (TargetValue 5) |
| **Ingress / DNS** | ALB DNS 직접 접근 | Route53 (`team5.cloud-infra.shop`) + WAF |

---

## 📈 5. 오토스케일링 & 관측성 파이프라인

### 1) Worker KEDA SQS Scaling
```text
CloudWatch SQS Metrics ──> YACE ──> Prometheus ──> KEDA ScaledObject ──> booking-worker replicas
```
- **Drift 무시 설정 (`ignoreDifferences`)**: ArgoCD가 HPA 및 KEDA의 동적 Replicas 변경을 이상 상태로 판단하지 않도록 `/spec/replicas` ignoreDifferences 패치가 적용되어 있습니다.

### 2) Prometheus & Grafana 연동
- `servicemonitor-booking.yaml`을 통해 Spring Boot Actuator `/actuator/prometheus` 15초 주기 scrape.
- `infra/monitoring` Kustomize로 Grafana Dashboard ConfigMap 4종 시각화 자동 프로비저닝.

---

## 🚀 6. CI/CD 파이프라인 연동

```text
[dev 흐름]
app repo push ──> GitHub Actions Build ──> dev ECR Push ──> config repo dev tag direct push ──> ArgoCD Auto Sync

[prod 승격 흐름]
dev 검증 완료 ──> prod promotion workflow ──> prod ECR Push ──> config repo prod tag PR 오픈 ──> PR 승인 & Merge ──> ArgoCD Sync
```
