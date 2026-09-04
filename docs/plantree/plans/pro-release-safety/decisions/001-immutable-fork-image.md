# Use Complete Immutable Fork Images

Date: 2026-09-03

## Context

手工在通用镜像上替换二进制无法清晰证明镜像与 fork 源码树一致，官方 OCI 标签还会造成来源误判。

## Decision

Pro 正式发布只接受从清单锁定源码树完整构建、带 fork 标签并由 GHCR sha256 摘要寻址的镜像。构建与部署保持人工分离。

## Consequences

发布速度依赖镜像仓库层缓存，但换取可追溯、可复现和可阻断的发布链路。手工二进制差分只能用于诊断，不再作为正式发布方式。
