import type { Dispatch, SetStateAction } from "react";
import type { LogFormState } from "../types";
import LogForm from "./LogForm";

interface Props {
  form: LogFormState;
  setForm: Dispatch<SetStateAction<LogFormState>>;
  onSubmit: () => void;
}

export default function LogView({ form, setForm, onSubmit }: Props) {
  return (
    <div>
      <div className="section-head">LOG SESSION</div>
      <div className="section-sub">Load = Duration × RPE</div>
      <LogForm form={form} setForm={setForm} onSubmit={onSubmit} />
    </div>
  );
}
