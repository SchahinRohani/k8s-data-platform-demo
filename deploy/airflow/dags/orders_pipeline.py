from __future__ import annotations

from datetime import datetime, timedelta, timezone

from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from airflow.sdk import DAG
from kubernetes.client import models as k8s


S3_ENV_FROM = [
    k8s.V1EnvFromSource(
        secret_ref=k8s.V1SecretEnvSource(name="pipeline-s3"),
    ),
]

TEMP_VOLUME = k8s.V1Volume(
    name="temporary-data",
    empty_dir=k8s.V1EmptyDirVolumeSource(),
)

TEMP_VOLUME_MOUNT = k8s.V1VolumeMount(
    name="temporary-data",
    mount_path="/tmp",
)

POD_SECURITY_CONTEXT = k8s.V1PodSecurityContext(
    run_as_non_root=True,
    run_as_user=10001,
    run_as_group=10001,
    fs_group=10001,
    seccomp_profile=k8s.V1SeccompProfile(type="RuntimeDefault"),
)

CONTAINER_SECURITY_CONTEXT = k8s.V1SecurityContext(
    allow_privilege_escalation=False,
    read_only_root_filesystem=True,
    capabilities=k8s.V1Capabilities(drop=["ALL"]),
)


with DAG(
    dag_id="orders_pipeline",
    description="Seed CSV data and transform it to Parquet",
    schedule=None,
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    catchup=False,
    max_active_runs=1,
    default_args={
        "retries": 2,
        "retry_delay": timedelta(seconds=10),
    },
    tags=["demo", "duckdb", "rustfs"],
) as dag:
    seed = KubernetesPodOperator(
        task_id="seed",
        name="pipeline-seed",
        namespace="data",
        image="demo-data-pipeline:dev",
        image_pull_policy="IfNotPresent",
        arguments=["seed"],
        env_from=S3_ENV_FROM,
        service_account_name="pipeline-runner",
        volumes=[TEMP_VOLUME],
        volume_mounts=[TEMP_VOLUME_MOUNT],
        security_context=POD_SECURITY_CONTEXT,
        container_security_context=CONTAINER_SECURITY_CONTEXT,
        container_resources=k8s.V1ResourceRequirements(
            requests={"cpu": "50m", "memory": "64Mi"},
            limits={"memory": "256Mi"},
        ),
        in_cluster=True,
        get_logs=True,
        log_events_on_failure=True,
        on_finish_action="delete_pod",
        execution_timeout=timedelta(minutes=5),
    )

    transform = KubernetesPodOperator(
        task_id="transform",
        name="pipeline-transform",
        namespace="data",
        image="demo-data-pipeline:dev",
        image_pull_policy="IfNotPresent",
        arguments=["transform"],
        env_from=S3_ENV_FROM,
        env_vars=[k8s.V1EnvVar(name="INPUT_WAIT_SECONDS", value="120")],
        service_account_name="pipeline-runner",
        volumes=[TEMP_VOLUME],
        volume_mounts=[TEMP_VOLUME_MOUNT],
        security_context=POD_SECURITY_CONTEXT,
        container_security_context=CONTAINER_SECURITY_CONTEXT,
        container_resources=k8s.V1ResourceRequirements(
            requests={"cpu": "100m", "memory": "128Mi"},
            limits={"memory": "512Mi"},
        ),
        in_cluster=True,
        get_logs=True,
        log_events_on_failure=True,
        on_finish_action="delete_pod",
        execution_timeout=timedelta(minutes=5),
    )

    seed >> transform