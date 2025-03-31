import {randomUUID} from "node:crypto";

import {op_apply} from "ext:core/ops";

globalThis.DenoRider = {
  _applications: {},
  _handleApplicationResult: (applicationId, result) => {
    DenoRider._applications[applicationId].resolve(result);
    delete DenoRider._applications[applicationId];
  },
  _runtimeId: null,
  apply: (module, functionName, args) => {
    if (typeof module !== "string") {
      throw new Error(`Not a string: ${module}`);
    }
    if (typeof functionName !== "string") {
      throw new Error(`Not a string: ${functionName}`);
    }
    if (!Array.isArray(args)) {
      throw new Error(`Not an array: ${args}`);
    }
    const applicationId = randomUUID();
    const promise = new Promise((resolve, reject) => {
      DenoRider._applications[applicationId] = {reject, resolve};
    });
    op_apply(DenoRider._runtimeId, applicationId, module, functionName, JSON.stringify(args));
    return promise;
  },
};
