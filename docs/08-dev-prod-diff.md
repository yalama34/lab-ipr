# Отличия dev и prod

В рамках лабораторной работы реализованы следующие отличия между окружениями `dev` и `prod` через kustomize overlays:

1. **Реплики:**
   - `dev`: 1 реплика для всех сервисов.
   - `prod`: 2 реплики для `frontend`, `bff`, `user-service`, `message-service`.
2. **Ресурсы:**
   - `dev`: ресурсы не заданы (или заданы базовые)
   - `prod`: добавлены строгие `requests` (CPU 100m, Memory 128Mi) и `limits` (CPU 250m, Memory 256Mi).
3. **Ingress Host:**
   - `dev`: `dev.messager.local`
   - `prod`: `messager.example.com`
4. **Теги образов:**
   - `dev`: `latest`
   - `prod`: `stable` (в реальном проекте должен быть конкретный semver/sha)
