# Velero — Plano de Instalação Segura no EKS eksmaringa-dev

> **Documento gerado em:** 2026-08-09  
> **Cluster:** eksmaringa-dev (EKS v1.36.2, sa-east-1)  
> **Account AWS:** 644266601430  
> **Impacto:** ZERO nos workloads existentes

---

## 1. Análise do Cluster Atual

### Infraestrutura

| Item | Valor |
|------|-------|
| Cluster | `eksmaringa-dev` (EKS v1.36.2) |
| Região | `sa-east-1` |
| Nodes | 9 (7× m5a.xlarge, 1× m5ad.xlarge, 1× t3.medium) |
| Gerenciamento | Rancher 2.x (cattle-system) |
| Ingress | Traefik (2 réplicas, LB externo + interno) |
| CSI Drivers | `ebs.csi.aws.com`, `efs.csi.aws.com` |
| Storage Classes | `gp3` (default), `gp2` (legacy) |
| VolumeSnapshot CRDs | **NÃO instalados** |
| OIDC Provider | ✅ Configurado |

### Namespaces Críticos (com dados persistentes)

| Namespace | Workloads Principais | PVCs |
|-----------|---------------------|------|
| `plataforma-gov-dev` | Kafka (3×10Gi), MongoDB (50Gi), ClickHouse (50Gi), Prometheus (10Gi), Grafana, SonarQube, SmartPass, Redis | ~19 PVCs |
| `posthog-maringa` | ClickHouse (100Gi), Kafka (20Gi), Postgres (20Gi), Elasticsearch, SeaweedFS, MinIO | ~8 PVCs |
| `gitlab` | Gitaly (50Gi) | 1 PVC |
| `x-via-openbao` | OpenBao (audit 10Gi) | 1 PVC |
| `xvia-ss` | (recente, verificar) | - |

### Recursos Disponíveis (folga para Velero)

| Node | CPU% | MEM% |
|------|------|------|
| ip-10-1-42-216 (m5ad.xlarge) | 1% | 18% |
| ip-10-1-44-199 (m5a.xlarge) | 1% | 18% |
| ip-10-1-63-206 (m5a.xlarge) | 4% | 31% |
| ip-10-1-38-149 (m5a.xlarge) | 10% | 53% |

> **Conclusão:** Há capacidade de sobra para o Velero (consome ~256Mi RAM + 100m CPU).

---

## 2. Pré-requisitos Identificados

| Pré-requisito | Status | Ação Necessária |
|---------------|--------|-----------------|
| CSI EBS Driver | ✅ Instalado | Nenhuma |
| OIDC Provider para IRSA | ✅ Configurado | Nenhuma |
| Bucket S3 para backups | ❌ Não existe | **Criar** |
| IAM Role para Velero (IRSA) | ❌ Não existe | **Criar** |
| VolumeSnapshot CRDs | ❌ Não instalados | **Instalar** (para CSI snapshots) |
| VolumeSnapshotClass | ❌ Não existe | **Criar** |
| Namespace velero | ❌ Não existe | Criado automaticamente na instalação |

---

## 3. Plano de Instalação Segura (Passo a Passo)

### Fase 1 — Preparação AWS (fora do cluster)

#### 1.1. Criar bucket S3 com encriptação

```bash
# Criar bucket dedicado para backups Velero
aws s3api create-bucket \
  --bucket eksmaringa-dev-velero-backups \
  --region sa-east-1 \
  --create-bucket-configuration LocationConstraint=sa-east-1

# Habilitar versionamento (proteção contra deleção acidental)
aws s3api put-bucket-versioning \
  --bucket eksmaringa-dev-velero-backups \
  --versioning-configuration Status=Enabled

# Encriptação SSE-S3 (padrão)
aws s3api put-bucket-encryption \
  --bucket eksmaringa-dev-velero-backups \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'

# Bloquear acesso público
aws s3api put-public-access-block \
  --bucket eksmaringa-dev-velero-backups \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

# Lifecycle: deletar backups antigos automaticamente (90 dias)
aws s3api put-bucket-lifecycle-configuration \
  --bucket eksmaringa-dev-velero-backups \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "ExpireOldBackups",
        "Status": "Enabled",
        "Filter": {"Prefix": "backups/"},
        "Expiration": {"Days": 90}
      },
      {
        "ID": "TransitionToIA",
        "Status": "Enabled",
        "Filter": {"Prefix": "backups/"},
        "Transitions": [
          {"Days": 30, "StorageClass": "STANDARD_IA"}
        ]
      }
    ]
  }'
```

#### 1.2. Criar IAM Policy para Velero

```bash
cat > /tmp/velero-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VeleroEC2Permissions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    },
    {
      "Sid": "VeleroS3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::eksmaringa-dev-velero-backups/*"
    },
    {
      "Sid": "VeleroS3ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::eksmaringa-dev-velero-backups"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name VeleroEKSMaringaDev \
  --policy-document file:///tmp/velero-policy.json \
  --description "Velero backup permissions for eksmaringa-dev cluster"
```

#### 1.3. Criar IAM Role com IRSA (sem credenciais estáticas)

```bash
# Variáveis
ACCOUNT_ID=644266601430
OIDC_ID=E06B843FFDFB450D2F97C7FB47B55420
NAMESPACE=velero
SERVICE_ACCOUNT=velero-server

# Trust policy para IRSA
cat > /tmp/velero-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.sa-east-1.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.sa-east-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
          "oidc.eks.sa-east-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Criar a role
aws iam create-role \
  --role-name VeleroEKSMaringaDev \
  --assume-role-policy-document file:///tmp/velero-trust-policy.json \
  --description "Velero IRSA role for eksmaringa-dev"

# Anexar a policy
aws iam attach-role-policy \
  --role-name VeleroEKSMaringaDev \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/VeleroEKSMaringaDev
```

### Fase 2 — Instalar VolumeSnapshot CRDs (pré-requisito para CSI snapshots)

```bash
# Instalar CRDs do VolumeSnapshot (v1, compatível com EKS 1.36)
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Instalar snapshot-controller (se não vier com o EKS por padrão)
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

# Verificar
kubectl get crd | grep volumesnapshot
```

#### Criar VolumeSnapshotClass para EBS

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ebs-csi-snapclass
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: ebs.csi.aws.com
deletionPolicy: Retain
EOF
```

### Fase 3 — Instalar Velero via Helm

#### 3.1. Adicionar repositório Helm

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
```

#### 3.2. Criar values.yaml

```bash
cat > /tmp/velero-values.yaml << 'EOF'
# === Velero Helm Values para eksmaringa-dev ===

# Configuração principal
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: eksmaringa-dev-velero-backups
      prefix: backups
      config:
        region: sa-east-1
  
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: sa-east-1

  # Usar Kopia como uploader de volumes (substitui Restic)
  uploaderType: kopia

  # Features
  features: EnableCSI

  # Backup default settings
  defaultVolumesToFsBackup: false  # Usar CSI snapshots por padrão

# ServiceAccount com IRSA (sem credenciais estáticas!)
serviceAccount:
  server:
    create: true
    name: velero-server
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::644266601430:role/VeleroEKSMaringaDev"

# Não precisamos de credentials secret (usando IRSA)
credentials:
  useSecret: false

# Node Agent (DaemonSet para backup file-level com Kopia)
deployNodeAgent: true
nodeAgent:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1024Mi

# Resources do Velero Server
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi

# Plugin AWS
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.0
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins
  - name: velero-plugin-for-csi
    image: velero/velero-plugin-for-csi:v0.8.0
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins

# Schedules automáticos (criados junto com a instalação)
schedules:
  # Backup diário de todos os namespaces (recursos + volumes)
  daily-all-namespaces:
    disabled: false
    schedule: "0 3 * * *"  # 03:00 BRT (06:00 UTC)
    useOwnerReferencesInBackup: false
    template:
      ttl: "168h"  # Retém por 7 dias
      storageLocation: default
      volumeSnapshotLocations:
        - default
      includedNamespaces:
        - plataforma-gov-dev
        - gitlab
        - posthog-maringa
        - x-via-openbao
        - xvia-ss
        - testca
      snapshotMoveData: false
  
  # Backup semanal completo (retém 30 dias)
  weekly-full:
    disabled: false
    schedule: "0 4 * * 0"  # Domingos 04:00 BRT
    useOwnerReferencesInBackup: false
    template:
      ttl: "720h"  # 30 dias
      storageLocation: default
      volumeSnapshotLocations:
        - default
      includedNamespaces:
        - "*"
      excludedNamespaces:
        - kube-system
        - kube-public
        - kube-node-lease
        - cattle-system
        - cattle-fleet-system
        - cattle-fleet-local-system
        - cattle-capi-system
        - cattle-turtles-system
        - cattle-ui-plugin-system
        - cattle-global-data
        - cattle-impersonation-system
        - cattle-local-user-passwords
      snapshotMoveData: false
EOF
```

#### 3.3. Instalar com Helm (dry-run primeiro!)

```bash
# ⚠️ DRY-RUN: Validar antes de aplicar
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --values /tmp/velero-values.yaml \
  --version 8.2.0 \
  --dry-run

# Se dry-run OK, instalar de verdade:
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --values /tmp/velero-values.yaml \
  --version 8.2.0 \
  --wait
```

### Fase 4 — Validação Pós-Instalação

```bash
# 4.1. Verificar pods Velero
kubectl get pods -n velero
# Esperado: velero-XXXX (Running) + node-agent-XXXX em cada node

# 4.2. Verificar BackupStorageLocation
kubectl get backupstoragelocation -n velero
# Esperado: STATUS = Available

# 4.3. Verificar VolumeSnapshotLocation
kubectl get volumesnapshotlocation -n velero

# 4.4. Verificar conectividade S3 (via logs)
kubectl logs -n velero -l app.kubernetes.io/name=velero --tail=20

# 4.5. Instalar CLI do Velero (se não tiver)
brew install velero

# 4.6. Verificar status geral
velero version
velero backup-location get
velero snapshot-location get
```

### Fase 5 — Teste de Backup Seguro (sem impacto)

```bash
# 5.1. Backup de um namespace pequeno/não-crítico primeiro
velero backup create test-xvia-ss \
  --include-namespaces xvia-ss \
  --wait

# 5.2. Verificar se completou
velero backup describe test-xvia-ss
velero backup logs test-xvia-ss

# 5.3. Teste de restore em namespace DIFERENTE (sem afetar produção!)
velero restore create test-restore-xvia-ss \
  --from-backup test-xvia-ss \
  --namespace-mappings xvia-ss:xvia-ss-restore-test \
  --wait

# 5.4. Verificar o restore
kubectl get all -n xvia-ss-restore-test

# 5.5. Limpar namespace de teste
kubectl delete namespace xvia-ss-restore-test

# 5.6. Se tudo OK, testar backup com volumes (plataforma-gov-dev)
velero backup create test-plataforma-volumes \
  --include-namespaces plataforma-gov-dev \
  --default-volumes-to-fs-backup=true \
  --wait
```

---

## 4. Garantias de Segurança (Zero Impacto)

| Preocupação | Mitigação |
|-------------|-----------|
| Velero pode derrubar pods? | **NÃO** — Velero é read-only durante backup (lê API + snapshots) |
| Snapshot afeta performance do EBS? | Mínimo — snapshots EBS são incrementais e não bloqueantes |
| DaemonSet consome recursos? | node-agent usa limits (1 CPU, 1Gi RAM) e só ativa durante backup |
| IRSA vaza credenciais? | **NÃO** — tokens temporários via STS, sem chaves estáticas |
| Backup falha: afeta cluster? | **NÃO** — falha de backup é isolada no namespace velero |
| Restore sobrescreve produção? | Só se executado manualmente no **mesmo** namespace |

---

## 5. Estratégia de Backup Recomendada

### Política de Retenção

| Tipo | Frequência | Retenção | Escopo |
|------|-----------|----------|--------|
| Diário | 03:00 UTC-3 | 7 dias | Namespaces críticos |
| Semanal | Domingos 04:00 | 30 dias | Cluster completo (exceto system) |
| Antes de mudanças | Manual | 30 dias | Namespace alvo |

### Namespaces Prioritários

1. **plataforma-gov-dev** — MongoDB 50Gi, Kafka 30Gi, ClickHouse 50Gi
2. **gitlab** — Gitaly 50Gi (código fonte)
3. **posthog-maringa** — ClickHouse 100Gi, Postgres 20Gi
4. **x-via-openbao** — Secrets vault
5. **xvia-ss** — Security servers X-Road

### Volumes: CSI Snapshot vs File-Level (Kopia)

| Método | Quando usar | Vantagem |
|--------|-------------|----------|
| CSI Snapshot (EBS) | Volumes grandes (>20Gi), databases | Rápido, incremental, zero I/O no pod |
| Kopia (file-level) | Volumes pequenos, dados que precisam de portabilidade | Funciona cross-region, independente de cloud |

> **Recomendação:** Usar CSI Snapshots para databases (MongoDB, Postgres, ClickHouse, Kafka) e Kopia para volumes menores e configs.

---

## 6. Comandos Úteis do Dia a Dia

```bash
# Ver todos os backups
velero backup get

# Criar backup manual antes de uma mudança
velero backup create pre-deploy-$(date +%Y%m%d-%H%M) \
  --include-namespaces plataforma-gov-dev \
  --wait

# Ver schedules
velero schedule get

# Pausar schedule (manutenção)
velero schedule pause daily-all-namespaces

# Retomar schedule
velero schedule unpause daily-all-namespaces

# Restore completo de um namespace
velero restore create restore-plataforma \
  --from-backup daily-all-namespaces-20260809030000 \
  --include-namespaces plataforma-gov-dev \
  --wait

# Restore de recurso específico
velero restore create restore-mongodb \
  --from-backup daily-all-namespaces-20260809030000 \
  --include-namespaces plataforma-gov-dev \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --selector app=mongodb \
  --wait

# Deletar backup antigo
velero backup delete test-xvia-ss --confirm
```

---

## 7. Monitoramento (Opcional)

### Métricas Prometheus

Velero expõe métricas em `:8085/metrics`. Adicionar ao Prometheus:

```yaml
# ServiceMonitor (se usar Prometheus Operator)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: velero
  namespace: velero
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: velero
  endpoints:
    - port: http-monitoring
      interval: 30s
```

### Alertas Importantes

```yaml
# Alerta: backup falhou
- alert: VeleroBackupFailed
  expr: velero_backup_failure_total > velero_backup_failure_total offset 1h
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Velero backup failed"

# Alerta: BackupStorageLocation indisponível
- alert: VeleroStorageUnavailable
  expr: velero_backup_storage_location_available == 0
  for: 10m
  labels:
    severity: critical
```

---

## 8. Checklist de Execução

```
[✅] 1. Criar bucket S3 (eksmaringa-dev-velero-backups) — DONE 2026-08-09
[✅] 2. Configurar encriptação + versionamento + lifecycle — DONE 2026-08-09
[✅] 3. Criar IAM Policy (VeleroEKSMaringaDev) — DONE 2026-08-09
[✅] 4. Criar IAM Role com IRSA trust — DONE 2026-08-09
[✅] 5. Instalar VolumeSnapshot CRDs (v8.2.0) — DONE 2026-08-09
[✅] 6. Criar VolumeSnapshotClass (ebs-csi-snapclass) — DONE 2026-08-09
[✅] 7. Instalar Velero via Helm (chart 12.1.0, app v1.18.1) — DONE 2026-08-09
[✅] 8. Verificar pods + BSL disponível — DONE (BSL Available)
[✅] 9. Backup de teste (external-secrets, 28 itens, 4s) — DONE 2026-08-09
[✅] 10. Restore de teste (namespace diferente, 23 itens OK) — DONE 2026-08-09
[✅] 11. Schedules automáticos ativados — daily (06:00 UTC) + weekly (dom 07:00 UTC)
[ ] 12. Configurar alertas Prometheus (opcional)
```

### Recursos criados

| Recurso | ARN / Nome |
|---------|-----------|
| Bucket S3 | `eksmaringa-dev-velero-backups` (sa-east-1) |
| IAM Policy | `arn:aws:iam::644266601430:policy/VeleroEKSMaringaDev` |
| IAM Role (IRSA) | `arn:aws:iam::644266601430:role/VeleroEKSMaringaDev` |
| Helm Release | `velero` (namespace: velero, chart: 12.1.0) |
| VolumeSnapshotClass | `ebs-csi-snapclass` |
| Schedule diário | `velero-daily-critical-namespaces` (06:00 UTC, 7d retenção) |
| Schedule semanal | `velero-weekly-full-cluster` (dom 07:00 UTC, 30d retenção) |

---

## 9. Rollback (Remover Velero se necessário)

```bash
# Remover instalação (não afeta workloads!)
helm uninstall velero -n velero
kubectl delete namespace velero

# Remover CRDs (opcional)
kubectl delete crd \
  backups.velero.io \
  backupstoragelocations.velero.io \
  deletebackuprequests.velero.io \
  downloadrequests.velero.io \
  podvolumebackups.velero.io \
  podvolumerestores.velero.io \
  restores.velero.io \
  schedules.velero.io \
  serverstatusrequests.velero.io \
  volumesnapshotlocations.velero.io

# Remover recursos AWS (se quiser limpar tudo)
aws s3 rb s3://eksmaringa-dev-velero-backups --force
aws iam detach-role-policy --role-name VeleroEKSMaringaDev \
  --policy-arn arn:aws:iam::644266601430:policy/VeleroEKSMaringaDev
aws iam delete-role --role-name VeleroEKSMaringaDev
aws iam delete-policy --policy-arn arn:aws:iam::644266601430:policy/VeleroEKSMaringaDev
```

---

## 10. Referências

- [Velero Docs](https://velero.io/docs/)
- [Velero AWS Plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws)
- [EKS + Velero Best Practices](https://aws.amazon.com/blogs/containers/backup-and-restore-your-amazon-eks-cluster-resources-using-velero/)
- [CSI Snapshotter](https://github.com/kubernetes-csi/external-snapshotter)
