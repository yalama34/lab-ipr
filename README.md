# Runbook: мессенджер в Kubernetes (Minikube / аналог)

Пошаговый порядок развёртывания и типовые сбои. Предполагается репозиторий с `kustomize`: `k8s/base`, `k8s/overlays/dev|prod`, `argocd/`, CSI-скрипты в `k8s/infra/ctrox-csi/`.

---

## 1. Подготовка кластера и меток узлов

Сервисы завязаны на `nodeAffinity` (`workload=system` для Postgres/MinIO, `workload=app` для приложения, для `message-service` ещё предпочтение `disk=fast`). Без меток Pod’ы останутся в `Pending`.

Проверка:

```bat
kubectl get nodes --show-labels
```

Назначьте метки в соответствии с манифестами (пример для minikube с несколькими нодами - см. схему узлов в задании)

---

## 2. Установка S3 CSI (ctrox/csi-s3), один раз на кластер

Upstream-манифесты часто ссылаются на недоступные образы; в репозитории скрипты подменяют теги и патчат DNS.

**Важно:** DaemonSet драйвера обычно с **hostNetwork**. Без `dnsPolicy: ClusterFirstWithHostNet` под на узле резолвит `.svc.cluster.local` через DNS хоста (например minikube `192.168.65.254`), а не CoreDNS — монтирование падает с `no such host`.

- Windows: `powershell -ExecutionPolicy Bypass -File k8s\infra\ctrox-csi\install.ps1`
- Linux/macOS: `sh k8s/infra/ctrox-csi/install.sh`

Дождитесь готовности подов `csi-s3`, `csi-attacher-s3`, `csi-provisioner-s3` в `kube-system`.

---

## 3. Подготовка перед деплоем приложения

1. Скопируйте `k8s/base/secret.example.yaml` в `k8s/base/secret.yaml` (или используйте ваш механизм секретов) и выставьте реальные значения БД и MinIO/CSI
2. **Секрет `csi-s3-secret` (namespace `messager`):**
  - `accessKeyID` / `secretAccessKey` — должны совпадать с учётными данными MinIO (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` берутся из того же секрета в базовых манифестах).
  - `endpoint` — **URL API MinIO с портом**, например `http://minio.messager.svc.cluster.local:9000`  
  Если после установки CSI монтирование всё ещё падает с `lookup minio... on 192.168.x.x: no such host`, временно укажите **ClusterIP** сервиса MinIO: `kubectl get svc minio -n messager -o jsonpath="{.spec.clusterIP}"`, затем `http://<IP>:9000`. Без `:9000` запросы пойдут на порт 80 и получите `connection refused`
  - `region` — для mounter **s3fs** задайте непустое значение, например `us-east-1`. Пустой `region` приводит к неверным аргументам монтирования и обрыву FUSE (`software caused connection abort`)

---

## 4. Применение приложения

```bat
kubectl apply -k k8s/overlays/dev
```

(для prod — `k8s/overlays/prod`)

Job `minio-s3-bootstrap` (sync-wave `-2` в аннотациях) создаёт бакет `uploads` и объект `.metadata.json`. Статический PV драйвера **ctrox** ожидает этот объект так же, как при динамическом provisioner.

**InitContainer** у `message-service` ждёт появления `.metadata.json` в бакете до старта основного контейнера.

После правок шаблона Job Kubernetes не обновит уже существующий Job (поле `spec.template` immutable):

```bat
kubectl delete job minio-s3-bootstrap -n messager
kubectl apply -k k8s/overlays/dev
```

---

## 5. S3-том: rclone, s3fs и `.metadata.json`

Ранее **I/O error** на `/app/upoads` при **mounter: rclone** связан с тем, что rclone при обращении к MinIO строил **virtual-hosted** URL вида `uploads.<endpoint>`, для FQDN сервиса это даёт несуществующее имя в DNS кластера.

**Рабочая конфигурация в этом репозитории:** в `k8s/base/csi.yaml` указан `mounter: s3fs`. В `.metadata.json` (генерирует bootstrap Job) поле `**Mounter`** должно быть `s3fs`*, `FSPath` — **пустая строка** (корень бакета): иначе s3fs при проверке пути может завершиться ошибкой и том не поднимется.

Убедитесь, что `volumeHandle` PV совпадает с именем бакета (`uploads`), и что бакет реально создан.

Иммутабельность: `spec.persistentVolumeSource` у PV менять нельзя. При смене атрибутов CSI-тома удалите PV и PVC, затем примените манифесты снова. Если PVC застрял, проверьте finalizers и `claimRef` у PV в статусе `Released`.

---

## 6. Проверка загрузки файлов (S3 CSI)

Запись в примонтированный каталог:

```bat
kubectl exec -n messager deploy/message-service -- sh -c "echo 'hello' > /app/uploads/test-csi.txt"
kubectl exec -n messager deploy/message-service -- ls -la /app/uploads
```

Проверка в MinIO:

```bat
kubectl exec -n messager deploy/minio -- sh -c "mc alias set local http://127.0.0.1:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" && mc cat local/uploads/test-csi.txt"
```

(или те же ключи, что в `csi-s3-secret`, если alias настраиваете вручную.)

---

## 7. Argo CD

1. Установка: `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
  Если ошибка `**metadata.annotations: Too long**` у CRD — применяйте с **server-side**:  
   `kubectl apply -n argocd -f ... --server-side --force-conflicts`
2. В `argocd/application-*.yaml` укажите `**repoURL`** и путь к overlay (`k8s/overlays/dev` и т.д.). Код должен быть **в удалённом репозитории**; иначе Argo сообщит, что путь не существует.
3. `automated` + `prune` + `selfHeal`
4. **Jobs (миграции, bootstrap):** при ошибке вида `spec.template: field is immutable` удалите соответствующий Job в кластере и дайте Argo пересоздать, либо синхронизируйте после удаления.
5. Образы Argo (например redis с `public.ecr.aws`) при проблемах сети можно заменить на зеркало (например `redis:7.2-alpine` с Docker Hub) — через `kubectl set image` в нужном deployment.

---

## 8. Возможные ошибки и их решение


| Ошибка                                           | Решение                                                                                                            |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `FailedMount`, `lookup minio... no such host`    | `dnsPolicy: ClusterFirstWithHostNet` у DaemonSet csi-s3; при необходимости `endpoint` = ClusterIP MinIO + `:9000`. |
| `connection refused` на IP MinIO                 | В `endpoint` забыт порт `:9000`.                                                                                   |
| `The specified bucket does not exist`            | Создать бакет `uploads`; проверить `volumeHandle` / `bucketName`.                                                  |
| `Endpoint: does not follow...` (пустой endpoint) | Заполнить `endpoint` в секрете и/или атрибутах PV по документации драйвера.                                        |
| PVC `Pending` при статическом PV                 | Пустой `storageClassName` у PV и PVC одинаковый; при `Released` — обнулить `spec.claimRef` или пересоздать PV.     |
| `FailedAttachVolume` / attacher                  | `CSIDriver` с `attachRequired: false` для `ch.ctrox.csi.s3-driver`.                                                |
| I/O error на `/app/uploads` при rclone           | Перейти на **s3fs** + корректный `.metadata.json` + непустой `region`.                                             |
| Миграции: БД не существует                       | Чистый том Postgres или ручное `CREATE DATABASE`; см. init SQL в `k8s/base/bootstrap/postgres-init/`               |


---

