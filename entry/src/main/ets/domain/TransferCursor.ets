import { TransferDirection } from './Enums';

export class TransferCursor {
  transferId: string = '';
  relPath: string = '';
  direction: TransferDirection = TransferDirection.Download;
  transferredBytes: number = 0;
  totalBytes: number = 0;
  updatedAt: number = 0;
}