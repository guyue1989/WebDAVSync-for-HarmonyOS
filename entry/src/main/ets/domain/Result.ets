export class Result<T> {
  success: boolean = false;
  data: T | null = null;
  errorCode: number = 0;
  errorMessage: string = '';

  static ok<T>(data: T): Result<T> {
    const r = new Result<T>();
    r.success = true;
    r.data = data;
    return r;
  }

  static fail<T>(code: number, message: string): Result<T> {
    const r = new Result<T>();
    r.success = false;
    r.errorCode = code;
    r.errorMessage = message;
    return r;
  }
}