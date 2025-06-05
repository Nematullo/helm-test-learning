#!/bin/bash

echo "Начинаем структурированную установку Argo CD в кластер Kubernetes."

NAMESPACE="argocd"

# --- ОБЯЗАТЕЛЬНАЯ УСТАНОВКА CRD (Custom Resource Definitions) ---
echo "Шаг: Применяем Custom Resource Definitions (CRD) для Argo CD."
echo "Это критично для работы Argo CD. Загружаем install.yaml..."

# Проверяем наличие wget или curl
if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
    echo "Ошибка: Для загрузки CRD требуется 'wget' или 'curl'. Пожалуйста, установите один из них."
    exit 1
fi

# Скачиваем CRD-файл, если его нет или если он пуст
CRD_FILE="argocd-crd.yaml"
if [ ! -f "$CRD_FILE" ] || [ ! -s "$CRD_FILE" ]; then
    echo "Загружаем CRD файл ($CRD_FILE)..."
    if command -v wget &> /dev/null; then
        wget https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.2/manifests/crds/install.yaml -O "$CRD_FILE" || { echo "Ошибка: Не удалось загрузить CRD файл. Проверьте подключение к интернету или URL."; exit 1; }
    elif command -v curl &> /dev/null; then
        curl -sSL https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.2/manifests/crds/install.yaml -o "$CRD_FILE" || { echo "Ошибка: Не удалось загрузить CRD файл. Проверьте подключение к интернету или URL."; exit 1; }
    fi
else
    echo "CRD файл ($CRD_FILE) уже существует. Используем его."
fi

# Применяем CRD
kubectl apply -f "$CRD_FILE" || { echo "Ошибка: Не удалось применить CRD ($CRD_FILE). Выходим."; exit 1; }
echo "CRD успешно применены. Ожидаем несколько секунд для их распространения в кластере..."
sleep 10 # Увеличена пауза для лучшей стабильности

# --- ВЫБОР ТИПА РАЗВЕРТЫВАНИЯ ARGO CD SERVER ---
ARGO_SERVER_DEPLOY_FILE=""
ARGO_SERVER_RESOURCE_TYPE=""

while true; do
    echo ""
    echo "Как вы хотите развернуть Argo CD Server?"
    echo "1) StatefulSet (Рекомендуется, под с предсказуемым именем: argocd-server-0)"
    echo "2) Deployment (Под с случайным именем: argocd-server-xxxxxxx)"
    read -p "Введите 1 или 2: " choice

    case $choice in
        1)
            ARGO_SERVER_DEPLOY_FILE="argocd-server-statefullset.yaml"
            ARGO_SERVER_RESOURCE_TYPE="StatefulSet"
            break
            ;;
        2)
            ARGO_SERVER_DEPLOY_FILE="argocd-server-deployment.yaml"
            ARGO_SERVER_RESOURCE_TYPE="Deployment"
            break
            ;;
        *)
            echo "Неверный ввод. Пожалуйста, введите 1 или 2."
            ;;
    esac
done

if [ ! -f "$ARGO_SERVER_DEPLOY_FILE" ]; then
    echo "Ошибка: Выбранный файл развертывания для Argo CD Server ($ARGO_SERVER_DEPLOY_FILE) не найден."
    echo "Убедитесь, что файлы 'argocd-server-statefullset.yaml' и 'argocd-server-deployment.yaml' существуют в текущей директории."
    exit 1
fi

echo "Выбран тип развертывания Argo CD Server: $ARGO_SERVER_RESOURCE_TYPE, используя файл: $ARGO_SERVER_DEPLOY_FILE"

# --- СПИСОК ФАЙЛОВ ДЛЯ БАЗОВОЙ УСТАНОВКИ ARGO CD (без CRD) ---
declare -a ARGO_CORE_FILES=(
    "argocd-namespace.yaml"
    "argocd-rbac.yaml"
    "argocd-rbac-cm.yaml"
    "keycloack-argocd-app-cm.yaml" # Убедитесь, что это имя файла с OIDC ConfigMap
    "argocd-repo-server-deployment.yaml"
    "argocd-repo-server-service.yaml"
    "argocd-application-controller-deployment.yaml"
    "argocd-application-controller-service.yaml"
    "$ARGO_SERVER_DEPLOY_FILE" # Здесь будет использован выбранный файл
    "argocd-server-service.yaml"
)

# Проверка и применение базовых манифестов Argo CD
echo "Шаг: Применяем основные компоненты Argo CD."
for file in "${ARGO_CORE_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "Применяем файл: $file"
        kubectl apply -f "$file" || { echo "Ошибка: Не удалось применить $file. Выходим."; exit 1; }
    else
        echo "Ошибка: Не найден обязательный файл $file. Убедитесь, что все базовые манифесты присутствуют."
        exit 1
    fi
done

echo ""
echo "Базовые компоненты Argo CD применены. Ожидаем их запуска..."

# --- ДИНАМИЧЕСКОЕ ОЖИДАНИЕ ГОТОВНОСТИ ПОДОВ ---
echo "Ожидаем готовности основных компонентов Argo CD..."

# Функция для ожидания ресурса (Deployment или StatefulSet)
wait_for_resource() {
    local resource_type="$1"
    local resource_name="$2"
    echo "Ожидаем $resource_type/$resource_name в неймспейсе '$NAMESPACE'..."
    kubectl wait --for=condition=ready "$resource_type"/"$resource_name" -n "$NAMESPACE" --timeout=300s
    if [ $? -ne 0 ]; then
        echo "Ошибка: Таймаут ожидания запуска $resource_type/$resource_name."
        return 1
    fi
    return 0
}

# Ожидаем готовности каждого основного компонента, используя выбранный тип для argocd-server
wait_for_resource "$ARGO_SERVER_RESOURCE_TYPE" "argocd-server" || { echo "Ошибка: Argo CD Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-application-controller" || { echo "Ошибка: Argo CD Application Controller не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-repo-server" || { echo "Ошибка: Argo CD Repo Server не готов. Проверьте логи."; exit 1; }


echo "Поды Argo CD готовы. Проверка статуса:"
kubectl get pods -n "$NAMESPACE"

echo ""
echo "Получение начального пароля администратора Argo CD:"
if kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; then
    ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo "Имя пользователя: admin"
    echo "Пароль: $ADMIN_PASSWORD"
else
    echo "Ошибка: Секрет 'argocd-initial-admin-secret' не найден. Возможно, Argo CD Server не инициализировался корректно."
fi

echo ""
echo "Argo CD UI будет доступен по адресу: http://<IP_вашего_узла_Kubernetes>:30080 (HTTP) или https://<IP_вашего_узла_Kubernetes>:30443 (HTTPS)"
echo "Не забудьте настроить 'Valid Redirect URIs' в Keycloak: https://<IP_вашего_узла_Kubernetes>:30443/api/v1/session/callback"
echo "Убедитесь, что 'url' в 'keycloack-argocd-app-cm.yaml' корректно настроен с вашим IP-адресом."

echo "---"
echo "Шаг: Применяем все остальные .yaml файлы, найденные в директории."

# Находим все .yaml файлы, кроме тех, что уже были применены в базовой установке
find . -type f -name "*.yaml" | while read -r file; do
    # Проверяем, был ли файл уже применён в списке ARGO_CORE_FILES или является ли он CRD-файлом
    IS_CORE_OR_CRD_FILE=false
    if [[ "$(basename "$file")" == "$(basename "$CRD_FILE")" ]]; then
        IS_CORE_OR_CRD_FILE=true
    fi
    for core_file in "${ARGO_CORE_FILES[@]}"; do
        if [[ "$(basename "$file")" == "$(basename "$core_file")" ]]; then
            IS_CORE_OR_CRD_FILE=true
            break
        fi
    done

    if ! $IS_CORE_OR_CRD_FILE; then
        echo "Применяем дополнительный файл: $file"
        kubectl apply -f "$file"
        if [ $? -ne 0 ]; then
            echo "Предупреждение: Произошла ошибка при применении файла $file. Возможно, это нормально для дополнительных ресурсов."
        fi
    fi
done

echo ""
echo "Установка Argo CD и применение дополнительных ресурсов завершены."
echo "Проверьте логи подов и состояние ресурсов, если возникли проблемы."