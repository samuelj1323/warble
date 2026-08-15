export interface LiveBlock {
  id: string;
  entryIds: string[];
  text: string;
  originalText: string;
  feedback: 'none' | 'correct' | 'corrected';
  live: boolean;
}
