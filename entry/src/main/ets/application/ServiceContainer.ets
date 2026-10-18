import { SecureStore } from '../infrastructure/SecureStore';
import { LocalFileService } from '../infrastructure/LocalFileService';
import { WebDavClient } from '../infrastructure/WebDavClient';
import { SyncStore } from '../infrastructure/SyncStore';
import { ConnectionManager } from './ConnectionManager';
import { SyncEngine } from './SyncEngine';
import { SyncScheduler } from './SyncScheduler';
import { NotificationService } from './NotificationService';
import { TaskManager } from './TaskManager';
import { BackgroundTaskService } from './BackgroundTaskService';
import { TrayService } from './TrayService';
import { StatusBarService } from './StatusBarService';

export class ServiceContainer {
  static syncStore: SyncStore = new SyncStore();
  static secureStore: SecureStore = new SecureStore();
  static localFileService: LocalFileService = new LocalFileService();
  static webDavClient: WebDavClient = new WebDavClient(ServiceContainer.secureStore, ServiceContainer.localFileService);
  static connectionManager: ConnectionManager = new ConnectionManager(ServiceContainer.secureStore, ServiceContainer.webDavClient);
  static syncEngine: SyncEngine = new SyncEngine(ServiceContainer.webDavClient, ServiceContainer.localFileService, ServiceContainer.syncStore, ServiceContainer.connectionManager);
  static notificationService: NotificationService = new NotificationService();
  static backgroundTaskService: BackgroundTaskService = new BackgroundTaskService();
  static trayService: TrayService = new TrayService();
  static statusBarService: StatusBarService = new StatusBarService();
  static syncScheduler: SyncScheduler = new SyncScheduler(ServiceContainer.localFileService, ServiceContainer.syncEngine, ServiceContainer.notificationService, ServiceContainer.backgroundTaskService);
  static taskManager: TaskManager = new TaskManager();
  static initialized: boolean = false;

  static async init(): Promise<void> {
    if (ServiceContainer.initialized) {
      return;
    }
    await ServiceContainer.syncStore.init();
    await ServiceContainer.connectionManager.init();
    await ServiceContainer.taskManager.init();
    ServiceContainer.initialized = true;
  }

  static async startupSync(): Promise<void> {
    const tasks = await ServiceContainer.taskManager.list();
    if (!tasks.success || tasks.data === null) {
      return;
    }
    for (const task of tasks.data) {
      await ServiceContainer.syncEngine.startSync(task);
      if (task.watchEnabled) {
        await ServiceContainer.syncScheduler.startWatch(task);
      }
      await ServiceContainer.syncScheduler.startPolling(task);
    }
  }

  // Reinstalling clears the folder grant, so the watchers started at launch have been polling
  // a folder they could not read. Restart them once the grant is live, so a local change is
  // picked up in about a second instead of waiting for the next app start.
  static async restartWatchers(): Promise<void> {
    const tasks = await ServiceContainer.taskManager.list();
    if (!tasks.success || tasks.data === null) {
      return;
    }
    for (const task of tasks.data) {
      await ServiceContainer.syncScheduler.stopWatch(task.id);
      await ServiceContainer.syncScheduler.stopPolling(task.id);
      await ServiceContainer.syncScheduler.startWatch(task);
      await ServiceContainer.syncScheduler.startPolling(task);
    }
  }
}