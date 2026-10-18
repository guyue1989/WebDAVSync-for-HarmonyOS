import preferences from '@ohos.data.preferences';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { util } from '@kit.ArkTS';
import { AppContext } from '../application/AppContext';
import { Result } from '../domain/Result';
import { BusinessError } from '@ohos.base';

const STORE_NAME = 'webdav_secure_store';
const MASTER_KEY = 'master_key_b64';
const CRED_PREFIX = 'cred_';

class EncryptedBlob {
  iv: string = '';
  tag: string = '';
  data: string = '';
}

export interface ISecureStore {
  saveCredential(credKey: string, credential: string): Promise<Result<string>>;
  loadCredential(ref: string): Promise<Result<string>>;
  deleteCredential(ref: string): Promise<void>;
}

export class SecureStore implements ISecureStore {
  private pref: preferences.Preferences | null = null;
  private masterKey: cryptoFramework.SymKey | null = null;
  private base64: util.Base64Helper = new util.Base64Helper();

  private async ensureInit(): Promise<boolean> {
    if (this.pref !== null && this.masterKey !== null) {
      return true;
    }
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return false;
    }
    this.pref = await preferences.getPreferences(ctx, STORE_NAME);
    this.masterKey = await this.loadOrCreateMasterKey();
    return this.masterKey !== null;
  }

  private async loadOrCreateMasterKey(): Promise<cryptoFramework.SymKey | null> {
    if (this.pref === null) {
      return null;
    }
    const generator = cryptoFramework.createSymKeyGenerator('AES256');
    const existing = await this.pref.get(MASTER_KEY, '') as string;
    if (existing !== '') {
      try {
        const material = this.base64.decodeSync(existing);
        if (material.length === 32) {
          const keyBlob: cryptoFramework.DataBlob = { data: material };
          return await generator.convertKey(keyBlob);
        }
      } catch (e) {
        // 主密钥还原失败或长度不合法（旧格式/损坏），落入重新生成
      }
    }
    const rand = cryptoFramework.createRandom();
    const randBlob = await rand.generateRandom(32);
    const material = randBlob.data;
    await this.pref.put(MASTER_KEY, this.base64.encodeToStringSync(material));
    await this.pref.flush();
    const keyBlob: cryptoFramework.DataBlob = { data: material };
    return await generator.convertKey(keyBlob);
  }

  private async encrypt(plain: string, key: cryptoFramework.SymKey): Promise<EncryptedBlob | null> {
    const iv = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      iv[i] = Math.floor(Math.random() * 256);
    }
    const ivParams: cryptoFramework.IvParamsSpec = {
      iv: { data: iv },
      algName: 'IvParamsSpec'
    };
    const cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, ivParams);
    const plainBytes = new util.TextEncoder().encodeInto(plain);
    const out = await cipher.doFinal({ data: plainBytes });
    const blob = new EncryptedBlob();
    blob.iv = this.base64.encodeToStringSync(iv);
    blob.tag = '';
    blob.data = this.base64.encodeToStringSync(out.data);
    return blob;
  }

  private async decrypt(blob: EncryptedBlob, key: cryptoFramework.SymKey): Promise<string> {
    const ivData = this.base64.decodeSync(blob.iv);
    const cipherData = this.base64.decodeSync(blob.data);
    const ivParams: cryptoFramework.IvParamsSpec = {
      iv: { data: ivData },
      algName: 'IvParamsSpec'
    };
    const cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, ivParams);
    const out = await cipher.doFinal({ data: cipherData });
    return new util.TextDecoder('utf-8').decodeToString(out.data);
  }

  async saveCredential(credKey: string, credential: string): Promise<Result<string>> {
    try {
      const ok = await this.ensureInit();
      if (!ok || this.pref === null || this.masterKey === null) {
        return Result.fail(1001, 'SecureStore 初始化失败');
      }
      const blob = await this.encrypt(credential, this.masterKey);
      if (blob === null) {
        return Result.fail(1002, '凭证加密失败');
      }
      const ref = CRED_PREFIX + credKey;
      await this.pref.put(ref, JSON.stringify(blob));
      await this.pref.flush();
      return Result.ok(ref);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, '凭证加密异常：' + err.message);
    }
  }

  async loadCredential(ref: string): Promise<Result<string>> {
    try {
      const ok = await this.ensureInit();
      if (!ok || this.pref === null || this.masterKey === null) {
        return Result.fail(1001, 'SecureStore 初始化失败');
      }
      const json = await this.pref.get(ref, '') as string;
      if (json === '') {
        return Result.fail(1003, '凭证不存在');
      }
      const blob = JSON.parse(json) as EncryptedBlob;
      const plain = await this.decrypt(blob, this.masterKey);
      return Result.ok(plain);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, '凭证解密异常：' + err.message);
    }
  }

  async deleteCredential(ref: string): Promise<void> {
    const ok = await this.ensureInit();
    if (!ok || this.pref === null) {
      return;
    }
    await this.pref.delete(ref);
    await this.pref.flush();
  }
}