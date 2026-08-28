import * as fs from "fs/promises";
import * as path from "path";

export enum Stage {
  ComingSoon = 0,
  Open = 1,
  Canceled = 2,
  PreFunded = 3,
  Funded = 4,
  Repaid = 5,
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

export function getFilePath(savePath: string, fileName: string): string {
  if (path.isAbsolute(savePath)) {
    return path.join(savePath, fileName);
  } else {
    return path.resolve(process.cwd(), savePath, fileName);
  }
}

export async function readJsonFile(filePath: string): Promise<any> {
  try {
    const data = await fs.readFile(filePath, "utf8");
    return JSON.parse(data);
  } catch (error) {
    console.error("Error: ", error);
    throw error;
  }
}

export async function writeJsonFile(filePath: string, data: any): Promise<void> {
  try {
    const jsonString = JSON.stringify(data, null, 2);
    await fs.writeFile(filePath, jsonString, "utf8");
    console.log("Done");
  } catch (error) {
    console.error("Error: ", error);
    throw error;
  }
}
