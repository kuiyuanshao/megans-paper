match_types <- function(new_df, orig_df) {
  common <- intersect(names(orig_df), names(new_df))
  out <- new_df
  
  for (nm in common) {
    tmpl <- orig_df[[nm]]
    col <- out[[nm]]
    if (is.integer(tmpl))        out[[nm]] <- as.integer(col)
    else if (is.numeric(tmpl))   out[[nm]] <- as.numeric(col)
    else if (is.logical(tmpl))   out[[nm]] <- as.logical(col)
    else if (is.factor(tmpl)) {
      out[[nm]] <- factor(col,
                          levels = levels(tmpl),
                          ordered = is.ordered(tmpl))
    }
    else if (inherits(tmpl, "Date")) {
      out[[nm]] <- as.Date(col)
    } else if (inherits(tmpl, "POSIXct")) {
      tz <- attr(tmpl, "tzone")
      out[[nm]] <- as.POSIXct(col, tz = tz)
    }
    else {
      out[[nm]] <- as.character(col)
    }
  }
  out
}

create_bfi <- function(data, batch_size, phase1_t, phase2_t, data_mask){
  n <- ceiling(nrow(data) / batch_size)
  idx <- 1
  batches <- vector("list", n)
  for (i in 1:n){
    if (i == n){
      batch_size <- nrow(data) - batch_size * (n - 1)
    }
    batches[[i]] <- list(X = phase2_t[idx:(idx + batch_size - 1), ],
                         C = phase1_t[idx:(idx + batch_size - 1), ],
                         M = data_mask[idx:(idx + batch_size - 1), ])
    idx <- idx + batch_size
  }
  return (batches = batches)
}

generateImpute <- function(gnet, m = 5, 
                           data_original, data_norm, 
                           data_encode, data_training, data_mask,
                           phase2_vars, num_vars, num.normalizing, cat.encoding, 
                           batch_size, g_dim, device, 
                           phase1_t, phase2_t){
  imputed_data_list <- vector("list", m)
  gsample_data_list <- vector("list", m)
  batchforimpute <- create_bfi(data_original, batch_size, phase1_t, phase2_t, data_mask)
  data_mask <- as.matrix(1 - is.na(data_original))
  
  num_col <- sapply(data_original, is.numeric)
  phase2_num_idx <- which(num_col & names(data_original) %in% phase2_vars)
  data_original[which(is.na(data_original[, phase2_vars[1]])), phase2_num_idx] <- 0
  
  for (z in 1:m){
    output_list <- vector("list", length(batchforimpute))
    for (i in 1:length(batchforimpute)){
      batch <- batchforimpute[[i]]
      X <- batch$X
      C <- batch$C
      M <- batch$M

      fakez <- torch_normal(mean = 0, std = 1, size = c(X$size(1), g_dim))$to(device = device)
      fakez_C <- torch_cat(list(fakez, C), dim = 2)
      gsample <- gnet(fakez_C)
      gsample <- activation_fun(gsample, data_encode, phase2_vars)
      gsample <- torch_cat(list(gsample, C), dim = 2)
      output_list[[i]] <- as.matrix(gsample$detach()$cpu())
    }
    output_mat <- as.data.frame(do.call(rbind, output_list))
    names(output_mat) <- names(data_training)
    
    denormalize <- paste("denormalize", num.normalizing, sep = ".")
    decode <- paste("decode", cat.encoding, sep = ".")
    
    curr_gsample <- do.call(decode, args = list(
      data = output_mat,
      encode_obj = data_encode
    ))
    curr_gsample <- do.call(denormalize, args = list(
      data = curr_gsample,
      num_vars = num_vars, 
      norm_obj = data_norm
    ))
    #get the original order
    gsamples <- curr_gsample$data
    gsamples <- gsamples[, names(data_original)]
    
    imputations <- data_original
    # ---- numeric columns: use matrix arithmetic ---
    if (any(num_col)) {
      out_num <- data_mask[, num_col] * as.matrix(data_original[, num_col]) +
        (1 - data_mask[, num_col]) * as.numeric(as.matrix(gsamples[, num_col]))
      imputations[, num_col] <- out_num
    }
    # ---- non-numeric columns (factor / character / etc.) -------------
    if (any(!num_col)) {
      to_replace <- data_mask[, !num_col] == 0
      idx <- which(to_replace, arr.ind = TRUE)
      col_ids <- which(!num_col)[idx[, "col"]]
      imputations[cbind(idx[, "row"], col_ids)] <- gsamples[cbind(idx[, "row"], col_ids)]
    }
    
    #imputations <- as.data.frame(data_mask * as.matrix(data_original) + 
    #                               (1 - data_mask) * as.matrix(gsamples))
    imputed_data_list[[z]] <- match_types(imputations, data_original)
    gsample_data_list[[z]] <- match_types(gsamples, data_original)
  }
  return (list(imputation = imputed_data_list, gsample = gsample_data_list))
}
