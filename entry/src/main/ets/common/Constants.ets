/**
 * JMComic 全局常量定义
 * 对应 Python 项目中的 JmMagicConstants 和 JmModuleConfig
 */

// API 域名列表 (与 JMComic-qt Url2List 保持一致)
export const DOMAIN_API_LIST: string[] = [
  'www.cdnhth.club',
  'www.cdngwc.cc',
  'www.cdnhth.net',
  'www.cdnbea.net'
];

// 图片 CDN 域名列表
export const DOMAIN_IMAGE_LIST: string[] = [
  'cdn-msp.jmapiproxy1.cc',
  'cdn-msp.jmapiproxy2.cc',
  'cdn-msp2.jmapiproxy2.cc',
  'cdn-msp3.jmapiproxy2.cc',
  'cdn-msp.jmapinodeudzn.net',
  'cdn-msp3.jmapinodeudzn.net'
];

// 协议前缀
export const PROT: string = 'https://';

// 图片 URL 模板
export const JM_CDN_IMAGE_URL_TEMPLATE: string = PROT + 'cdn-msp.{domain}/media/photos/{photo_id}/{img_name}';

// APP 密钥
export const APP_TOKEN_SECRET: string = '18comicAPP';
export const APP_TOKEN_SECRET_2: string = '18comicAPPContent';
export const APP_DATA_SECRET: string = '185Hcomic3PAPP7R';
export const APP_VERSION: string = '2.0.20';

// Scramble 阈值
export const SCRAMBLE_220980: number = 220980;
export const SCRAMBLE_268850: number = 268850;
export const SCRAMBLE_421926: number = 421926;

// 搜索排序
export const ORDER_BY_LATEST: string = 'mr';
export const ORDER_BY_VIEW: string = 'mv';
export const ORDER_BY_PICTURE: string = 'mp';
export const ORDER_BY_LIKE: string = 'tf';
export const ORDER_MONTH_RANKING: string = 'mv_m';
export const ORDER_WEEK_RANKING: string = 'mv_w';
export const ORDER_DAY_RANKING: string = 'mv_t';

// 搜索时间段
export const TIME_TODAY: string = 't';
export const TIME_WEEK: string = 'w';
export const TIME_MONTH: string = 'm';
export const TIME_ALL: string = 'a';

// 分类
export const CATEGORY_ALL: string = '0';
export const CATEGORY_DOUJIN: string = 'doujin';
export const CATEGORY_SINGLE: string = 'single';
export const CATEGORY_SHORT: string = 'short';
export const CATEGORY_ANOTHER: string = 'another';
export const CATEGORY_HANMAN: string = 'hanman';
export const CATEGORY_MEIMAN: string = 'meiman';
export const CATEGORY_DOUJIN_COSPLAY: string = 'doujin_cosplay';
export const CATEGORY_3D: string = '3D';
export const CATEGORY_ENGLISH_SITE: string = 'english_site';

// 移动端 API 端点
export const API_SEARCH: string = '/search';
export const API_CATEGORIES_FILTER: string = '/categories/filter';
export const API_ALBUM: string = '/album';
export const API_CHAPTER: string = '/chapter';
export const API_SCRAMBLE: string = '/chapter_view_template';
export const API_FAVORITE: string = '/favorite';
export const API_FAVORITE_FOLDER: string = '/favorite_folder';
export const API_SETTING: string = '/setting';
export const API_LOGIN: string = '/login';
export const API_FORUM: string = '/forum';
export const API_COMMENT: string = '/comment';

// HTTP Headers
export const APP_HEADERS_TEMPLATE: Record<string, string> = {
  'Accept-Encoding': 'gzip, deflate',
  'user-agent': 'Mozilla/5.0 (Linux; Android 9; V1938CT Build/PQ3A.190705.11211812; wv) ' +
    'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36',
};

export const APP_HEADERS_IMAGE: Record<string, string> = {
  'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  'X-Requested-With': 'com.jiaohua_browser',
  'Referer': PROT + DOMAIN_API_LIST[0],
  'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
};

// 分页大小
export const PAGE_SIZE_SEARCH: number = 80;
export const PAGE_SIZE_FAVORITE: number = 20;

// 请求重试次数
export const DEFAULT_RETRY_TIMES: number = 3;

// 图片文件后缀
export const IMAGE_SUFFIX_LIST: string[] = ['.jpg', '.webp', '.png', '.gif'];

// 子分类映射
export const CATEGORY_SUB_MAP: Record<string, string> = {
  'doujin': 'CG',
  'single': 'chinese',
  'short': 'chinese',
};

// 分类中文名
export const CATEGORY_NAME_MAP: Record<string, string> = {
  '0': '最新',
  'doujin': '同人',
  'single': '单本',
  'short': '短篇',
  'another': '其他',
  'hanman': '韩漫',
  'meiman': '美漫',
  'doujin_cosplay': 'Cosplay',
  '3D': '3D',
  'english_site': '英文站',
};

export const ORDER_NAME_MAP: Record<string, string> = {
  'mr': '最新',
  'mv': '最多观看',
  'mp': '最多图片',
  'tf': '最多喜欢',
  'mv_m': '月排行',
  'mv_w': '周排行',
  'mv_t': '日排行',
};

export const TIME_NAME_MAP: Record<string, string> = {
  't': '今天',
  'w': '本周',
  'm': '本月',
  'a': '全部',
};
