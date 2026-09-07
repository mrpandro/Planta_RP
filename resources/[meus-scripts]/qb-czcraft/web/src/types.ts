export type OperationalStatus = 'STOPPED' | 'RUNNING';
export type BillStatus = 'PENDING' | 'ACTIVE' | 'PAUSED' | 'COMPLETED' | 'REMOVED';
export type BillMode = 'PRODUCE_X' | 'MAINTAIN_X';
export type OwnerType = 'PLAYER' | 'JOB' | 'GANG';
export type LocationType = 'HOUSE' | 'ORG';

export interface MachineData {
  machineUuid: string;
  machineType: string;
  serial: string;
  operationalStatus: OperationalStatus;
  blockedReason: string | null;
  blockedDetail: string | null;
  stockCapacity: number;
  usedWeight: number;
  reservedWeight: number;
  activeBillId: string | null;
  activeCycleId: string | null;
  nextDueAt: string | null;
  ownerType: OwnerType;
  ownerId: string;
  locationType: LocationType;
  locationId: string;
  version: number;
}

export interface StockRow {
  itemName: string;
  metadataKey: string;
  quantity: number;
  reservedQuantity: number;
  standardUnitCost: number;
  version: number;
}

export interface Bill {
  billId: string;
  machineUuid: string;
  recipeId: string;
  mode: BillMode;
  primaryOutput: string;
  targetQuantity: number;
  producedQuantity: number;
  enabled: boolean;
  status: BillStatus;
  blockReason: string | null;
  priority: string;
  version: number;
}

export interface RecipeInput {
  item: string;
  amount: number;
}

export interface RecipeOutput {
  item: string;
  amount: number;
}

export interface Recipe {
  id: string;
  machine: string;
  duration: number;
  enabled: boolean;
  access: string;
  inputs: RecipeInput[];
  outputs: RecipeOutput[];
  primaryOutput: string;
}

export interface OwnerOverview {
  machines: Array<{
    machineUuid: string;
    machineType: string;
    operationalStatus: OperationalStatus;
    locationType: LocationType;
    locationId: string;
  }>;
  totalMachines: number;
  activeBills: number;
  totalStockItems: number;
}

export interface NUIResponse<T> {
  success: boolean;
  data?: T;
  reason?: string;
}
