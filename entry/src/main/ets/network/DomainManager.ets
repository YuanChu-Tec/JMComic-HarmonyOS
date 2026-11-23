import { http } from '@kit.NetworkKit';
import { PROT, APP_HEADERS_TEMPLATE } from '../common/Constants';

/**
 * 死域名标记值：远大于正常失败计数
 * 对应 Java JmDomainManager.DEAD_MARK
 */
const DEAD_MARK = Math.floor(Number.MAX_SAFE_INTEGER / 2);

/** 域名状态快照类型 */
export class DomainStates {
  api: Record<string, number> = {};
  image: Record<string, number> = {};
}

/** 单次探活超时 (ms) */
const PROBE_TIMEOUT = 8000;

/** 后台复探间隔 (ms)，默认 5 分钟 */
const PERIODIC_PROBE_INTERVAL = 5 * 60 * 1000;

/**
 * 域名管理器
 *
 * 核心设计（参考 Java JmDomainManager）：
 * 1. 失败计数：每个域名跟踪失败次数，优先选择失败次数最少的域名
 * 2. 粘滞：记住上次成功的域名，只要它还是零失败就一直用，失败后才换下一个
 * 3. 并行探活：初始化时并行探测所有域名可达性，标记不可达域名
 * 4. 定期复探：后台定时重新探测已标记为不可达的域名，恢复后自动加入可用池
 * 5. 全死降级：所有域名都不可达时，重置所有计数回退到未探活状态
 *
 * 粘滞是为了让同一份列表在多次刷新间保持在同一个镜像上：
 * 轮询换域会让相邻两次刷新拿到不同镜像的数据，表现为列表内容每次刷新都变。
 */
export class DomainManager {
  private apiDomains: string[];
  private imageDomains: string[];
  private apiFailureCounts: Map<string, number> = new Map();
  private imageFailureCounts: Map<string, number> = new Map();
  private probeTimer: number | null = null;
  private apiClusterIndex: number = 0; // Round-robin 辅助（未粘滞时用）
  private imageClusterIndex: number = 0;
  private stickyApiDomain: string | null = null; // 上次成功的 API 域名
  private stickyImageDomain: string | null = null; // 上次成功的图片域名
  private selectedApiIndex: number = -1; // -1 = 自动选择
  private selectedImageIndex: number = -1; // -1 = 自动选择

  constructor(apiDomains: string[], imageDomains: string[]) {
    this.apiDomains = [...apiDomains];
    this.imageDomains = [...imageDomains];
    this.resetCounts();
  }

  /** 重置所有失败计数 */
  private resetCounts(): void {
    this.apiFailureCounts.clear();
    this.imageFailureCounts.clear();
    this.stickyApiDomain = null;
    this.stickyImageDomain = null;
    for (let d of this.apiDomains) {
      this.apiFailureCounts.set(d, 0);
    }
    for (let d of this.imageDomains) {
      this.imageFailureCounts.set(d, 0);
    }
  }

  // ─── 域名选择 ───

  /**
   * 获取最佳 API 域名
   * 手动选择优先；否则优先沿用上次成功的域名，只有它失败过才重新选
   */
  getBestApiDomain(): string {
    if (this.selectedApiIndex >= 0 && this.selectedApiIndex < this.apiDomains.length) {
      return this.apiDomains[this.selectedApiIndex];
    }
    let sticky = this.stickyApiDomain;
    if (sticky !== null && (this.apiFailureCounts.get(sticky) || 0) === 0) {
      return sticky;
    }
    return this.selectBest(this.apiDomains, this.apiFailureCounts, true);
  }

  /**
   * 获取最佳图片 CDN 域名
   * 手动选择优先；否则优先沿用上次成功的域名，只有它失败过才重新选
   */
  getBestImageDomain(): string {
    if (this.selectedImageIndex >= 0 && this.selectedImageIndex < this.imageDomains.length) {
      return this.imageDomains[this.selectedImageIndex];
    }
    let sticky = this.stickyImageDomain;
    if (sticky !== null && (this.imageFailureCounts.get(sticky) || 0) === 0) {
      return sticky;
    }
    return this.selectBest(this.imageDomains, this.imageFailureCounts, false);
  }

  /** 获取当前 API 线路索引（-1 为自动） */
  getSelectedApiIndex(): number {
    return this.selectedApiIndex;
  }

  /** 获取当前图片线路索引（-1 为自动） */
  getSelectedImageIndex(): number {
    return this.selectedImageIndex;
  }

  /** 设置 API 线路索引（-1 为自动） */
  setApiIndex(index: number): void {
    this.selectedApiIndex = index;
    console.info(`[DomainManager] API 线路切换为: ${index < 0 ? '自动' : `线路${index + 1}`}`);
  }

  /** 设置图片线路索引（-1 为自动） */
  setImageIndex(index: number): void {
    this.selectedImageIndex = index;
    console.info(`[DomainManager] 图片线路切换为: ${index < 0 ? '自动' : `线路${index + 1}`}`);
  }

  /**
   * 核心选择算法：选择失败计数最低的域名
   * 多个域名同为最低时，使用 round-robin 分散负载（API 与图片各自独立计数）
   */
  private selectBest(domains: string[], counts: Map<string, number>, isApi: boolean): string {
    if (domains.length === 0) {
      throw new Error('域名列表为空');
    }

    // 寻找最低失败计数
    let bestDomains: string[] = [];
    let bestCount = Number.MAX_SAFE_INTEGER;

    for (let d of domains) {
      let count = counts.get(d) || 0;
      if (count < bestCount) {
        bestCount = count;
        bestDomains = [d];
      } else if (count === bestCount) {
        bestDomains.push(d);
      }
    }

    // Round-robin 从同等最佳中选择
    if (isApi) {
      this.apiClusterIndex = (this.apiClusterIndex + 1) % bestDomains.length;
      return bestDomains[this.apiClusterIndex];
    }
    this.imageClusterIndex = (this.imageClusterIndex + 1) % bestDomains.length;
    return bestDomains[this.imageClusterIndex];
  }

  // ─── 成功/失败报告 ───

  /** 报告 API 域名请求成功：计数归零，并粘住这个域名 */
  reportApiSuccess(domain: string): void {
    if (this.apiFailureCounts.has(domain)) {
      this.apiFailureCounts.set(domain, 0);
      this.stickyApiDomain = domain;
    }
  }

  /** 报告 API 域名请求失败：增加失败计数，解除粘滞让下次重新选 */
  reportApiFailure(domain: string): void {
    let count = this.apiFailureCounts.get(domain);
    if (count !== undefined) {
      this.apiFailureCounts.set(domain, count + 1);
      if (this.stickyApiDomain === domain) {
        this.stickyApiDomain = null;
      }
    }
  }

  /** 报告图片域名成功：计数归零，并粘住这个域名 */
  reportImageSuccess(domain: string): void {
    if (this.imageFailureCounts.has(domain)) {
      this.imageFailureCounts.set(domain, 0);
      this.stickyImageDomain = domain;
    }
  }

  /** 报告图片域名失败：增加失败计数，解除粘滞让下次重新选 */
  reportImageFailure(domain: string): void {
    let count = this.imageFailureCounts.get(domain);
    if (count !== undefined) {
      this.imageFailureCounts.set(domain, count + 1);
      if (this.stickyImageDomain === domain) {
        this.stickyImageDomain = null;
      }
    }
  }

  // ─── 域名状态查询 ───

  /** 域名状态快照 */
  getDomainStates(): DomainStates {
    let api: Record<string, number> = {};
    let image: Record<string, number> = {};
    this.apiFailureCounts.forEach((v: number, k: string) => { api[k] = v; });
    this.imageFailureCounts.forEach((v: number, k: string) => { image[k] = v; });
    let states = new DomainStates();
    states.api = api;
    states.image = image;
    return states;
  }

  /** 检查指定域名是否被标记为不可达 */
  isDead(domain: string): boolean {
    if (this.apiFailureCounts.has(domain)) {
      return (this.apiFailureCounts.get(domain) || 0) >= DEAD_MARK;
    }
    if (this.imageFailureCounts.has(domain)) {
      return (this.imageFailureCounts.get(domain) || 0) >= DEAD_MARK;
    }
    return false;
  }

  // ─── 探活 ───

  /**
   * 并行探测所有域名的可达性。
   *
   * 对每个域名发起 HTTP HEAD 请求：
   * - 可达 → 失败计数归零
   * - 不可达 → 失败计数设为 DEAD_MARK
   *
   * 全死降级：如果所有域名都不可达，重置所有计数为 0
   *
   * 对应 Java JmDomainManager.probeAllDomains()
   */
  async probeAllDomains(): Promise<void> {
    console.info(`[DomainManager] 开始并行探活 API:${this.apiDomains.length} 图片:${this.imageDomains.length} 个域名...`);
    let startTime = Date.now();

    // 并行探测所有域名
    let allDomains = [...this.apiDomains, ...this.imageDomains];
    let results = await Promise.all(allDomains.map(d => this.probeSingleDomain(d)));

    // 处理 API 域名结果
    for (let i = 0; i < this.apiDomains.length; i++) {
      let domain = this.apiDomains[i];
      if (results[i]) {
        this.apiFailureCounts.set(domain, 0);
        console.info(`[DomainManager] API 域名可达: ${domain}`);
      } else {
        this.apiFailureCounts.set(domain, DEAD_MARK);
        console.warn(`[DomainManager] API 域名不可达: ${domain}`);
      }
    }

    // 处理图片域名结果
    let offset = this.apiDomains.length;
    for (let i = 0; i < this.imageDomains.length; i++) {
      let domain = this.imageDomains[i];
      if (results[offset + i]) {
        this.imageFailureCounts.set(domain, 0);
        console.info(`[DomainManager] 图片域名可达: ${domain}`);
      } else {
        this.imageFailureCounts.set(domain, DEAD_MARK);
        console.warn(`[DomainManager] 图片域名不可达: ${domain}`);
      }
    }

    // 全死降级检查
    this.checkAllDeadFallback();

    let elapsed = Date.now() - startTime;
    let aliveApi = this.apiDomains.filter(d => (this.apiFailureCounts.get(d) || 0) < DEAD_MARK).length;
    let aliveImage = this.imageDomains.filter(d => (this.imageFailureCounts.get(d) || 0) < DEAD_MARK).length;
    console.info(`[DomainManager] 探活完成 (${elapsed}ms): API ${aliveApi}/${this.apiDomains.length}, 图片 ${aliveImage}/${this.imageDomains.length}`);
  }

  /**
   * 全死降级：如果某类所有域名都不可达，重置该类所有计数
   */
  private checkAllDeadFallback(): void {
    // API 域名全死检查
    let allApiDead = this.apiDomains.length > 0 &&
      this.apiDomains.every(d => (this.apiFailureCounts.get(d) || 0) >= DEAD_MARK);
    if (allApiDead) {
      console.warn('[DomainManager] 所有 API 域名不可达，回退到未探活状态');
      this.apiDomains.forEach(d => this.apiFailureCounts.set(d, 0));
    }

    // 图片域名全死检查
    let allImageDead = this.imageDomains.length > 0 &&
      this.imageDomains.every(d => (this.imageFailureCounts.get(d) || 0) >= DEAD_MARK);
    if (allImageDead) {
      console.warn('[DomainManager] 所有图片域名不可达，回退到未探活状态');
      this.imageDomains.forEach(d => this.imageFailureCounts.set(d, 0));
    }
  }

  /**
   * 探测单个域名可达性
   * 通过 HTTP HEAD 请求探测根路径，超时 8 秒
   * 任何 HTTP 响应（包括 3xx/4xx）都视为可达，仅超时和连接失败视为不可达
   */
  private async probeSingleDomain(domain: string): Promise<boolean> {
    let httpRequest = http.createHttp();
    try {
      let url = `${PROT}${domain}/`;
      await httpRequest.request(url, {
        method: http.RequestMethod.HEAD,
        header: APP_HEADERS_TEMPLATE,
        connectTimeout: PROBE_TIMEOUT,
        readTimeout: PROBE_TIMEOUT,
      });
      // 收到响应即视为可达
      return true;
    } catch (err) {
      return false;
    } finally {
      httpRequest.destroy();
    }
  }

  // ─── 后台定期复探 ───

  /**
   * 启动后台定期复探。
   *
   * 每隔指定时间，对所有标记为 DEAD_MARK 的域名重新探活。
   * 如果某域名恢复可达，将其失败计数归零，自动回到可用池。
   *
   * 对应 Java JmDomainManager.startPeriodicProbe()
   */
  startPeriodicProbe(): void {
    if (this.probeTimer !== null) {
      return; // 已启动
    }
    console.info(`[DomainManager] 后台域名复探已启动，间隔 ${PERIODIC_PROBE_INTERVAL / 1000}s`);
    this.probeTimer = setInterval(() => {
      this.probeDeadDomains();
    }, PERIODIC_PROBE_INTERVAL);
  }

  /**
   * 复探所有死域名
   */
  private async probeDeadDomains(): Promise<void> {
    let deadApiDomains = this.apiDomains.filter(
      d => (this.apiFailureCounts.get(d) || 0) >= DEAD_MARK
    );
    let deadImageDomains = this.imageDomains.filter(
      d => (this.imageFailureCounts.get(d) || 0) >= DEAD_MARK
    );

    let allDead = [...deadApiDomains, ...deadImageDomains];
    if (allDead.length === 0) {
      return;
    }

    console.info(`[DomainManager] 后台复探 ${allDead.length} 个死域名...`);
    let results = await Promise.all(allDead.map(d => this.probeSingleDomain(d)));

    let recoveredCount = 0;
    for (let i = 0; i < allDead.length; i++) {
      let domain = allDead[i];
      if (results[i]) {
        // 域名已恢复，清零计数
        if (this.apiFailureCounts.has(domain)) {
          this.apiFailureCounts.set(domain, 0);
        }
        if (this.imageFailureCounts.has(domain)) {
          this.imageFailureCounts.set(domain, 0);
        }
        recoveredCount++;
        console.info(`[DomainManager] 域名已恢复: ${domain}`);
      }
    }

    if (recoveredCount > 0) {
      console.info(`[DomainManager] 复探完成: ${recoveredCount}/${allDead.length} 个域名已恢复`);
    }
  }

  /** 关闭后台复探定时器 */
  shutdown(): void {
    if (this.probeTimer !== null) {
      clearInterval(this.probeTimer);
      this.probeTimer = null;
      console.info('[DomainManager] 后台域名复探已关闭');
    }
  }

  /** 获取域名列表（只读） */
  getApiDomains(): string[] {
    return [...this.apiDomains];
  }

  getImageDomains(): string[] {
    return [...this.imageDomains];
  }
}
