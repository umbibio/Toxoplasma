library(edgeR)
library(limma)
library(openxlsx)
library(gplots)
library(dplyr)
library(tidyverse)

abs.path <- '~/work/ToxoplasmaGondii/'
#### Test the files
#### This folder contains the output of feature count. Change as appropriate
fc.files.dir  <- paste(abs.path, "RNAseqCounts/", sep = '')
### My feature coutn file names end in counts.txt, hence the grep. Change if not needed
fc.files      <- file.path(fc.files.dir, list.files(fc.files.dir)[grep("counts.txt$", list.files(fc.files.dir))])

## Creating the count table. The first column isgene ID
f <- read.table(fc.files[1], header = T, sep = '\t', stringsAsFactors = F)
f <- f[,c(1,7)]
colnames(f) <- c("GeneName", "Count1")

for(i in 2:length(fc.files)){
  tmp <- read.table(fc.files[i], header = T, sep = '\t', stringsAsFactors = F)
  tmp <- tmp[,c(1,7)]
  colnames(tmp) <- c("GeneName", paste("Count", i, sep = ''))
  f = merge(f, tmp, by.x = 1, by.y = 1)
  
}

## run5 are DNA data
RunInfo <- data.frame(Sample = gsub('_S.*', '', gsub('.counts.txt', '', basename(fc.files))), 
                      Count = paste('Count', 1:length(fc.files), sep = ''),
                      stringsAsFactors = F)
## This was manually constructed from RNAseq Info excell files
sample.info.file <- paste(abs.path, 'RNAseqCounts/sampleInfo.xlsx', sep = '')
RNAseqInfo <- read.xlsx(sample.info.file)
RNAseqInfo <- left_join(RNAseqInfo, RunInfo, by = c('Sample.ID' = 'Sample'))

RNAseqInfo.B2 <- RNAseqInfo %>% dplyr::filter((Clone == 'B2' | Clone == 'RH' | Clone == 'B') & cond != 'fresh')
RNAseqInfo.B2$treatment <- paste(RNAseqInfo.B2$cond, RNAseqInfo.B2$passage, sep = '.')

RNAseqInfo.B2 <- RNAseqInfo.B2 %>% mutate(Names = paste(passage, cond, 'rep', Bio_rep, sep = '.'))

## Detecting Bias
y <- f %>% dplyr::select(c('GeneName', RNAseqInfo.B2$Count)) ## Just B, RH and B2 samples
## Filtering low expressions
CPM  <- cpm(y[,2:ncol(y)])
keep <-  rowSums(CPM > 2) >= 3
x <- y[keep,2:ncol(y)]
rownames(x) <- y$GeneName[keep]

treatment <- RNAseqInfo.B2$treatment[match(colnames(x), RNAseqInfo.B2$Count)]
treatment <- factor(treatment, levels = unique(treatment))

y <- DGEList(counts=x, group=treatment)
y <- calcNormFactors(y)
y$samples
plotMDS(y)

#design <- model.matrix(~0+treatment, data=y$samples)
#colnames(design) <- levels(y$samples$group)
#y <- estimateDisp(y,design)
#plotBCV(y)



### Trying to remove batch effect from CPM values
logCPM <- cpm(y, log=TRUE, prior.count=3, normalized.lib.sizes=TRUE)
colnames(logCPM) <- RNAseqInfo.B2$Names[match(colnames(logCPM), RNAseqInfo.B2$Count)]
## MDS and heatmap clearly show a batch effect that is random
#heatmap(logCPM,cexCol = 0.5)
plotMDS(logCPM, cex = 0.5) 
## Hierarchical clustering to identify batches
clusters <- hclust(dist(t(logCPM)))
plot(clusters)
clusterCut <- cutree(clusters, 3) ## pick 3 clusters
CC <- data.frame(Samples = names(clusterCut), Batch = clusterCut, stringsAsFactors = F)
RNAseqInfo.B2 <- left_join(RNAseqInfo.B2, CC, by = c('Names' = 'Samples'))
DD <- RNAseqInfo.B2 %>% dplyr::select(c('cond', 'passage', 'treatment', 'Batch')) %>%
  mutate_all(funs(factor(.,levels = unique(.))))

## Correct the batches
batch <- DD$Batch
cond <- DD$cond
passage <- DD$passage
treatment <- DD$treatment
#treatment <- relevel(treatment, ref="extra.RH")


design <- model.matrix(~treatment, data=y$samples) ## treatment dfesign matrix

logCPM_no_batch <- removeBatchEffect(logCPM, batch=batch, design=design) 

## Seems like batch effect is corrected and clustres represent extra vs intra.
#heatmap(logCPM_no_batch,cexCol = 0.5)
plotMDS(logCPM_no_batch, cex = 0.6) 


####### EdgeR DEG analysis with Batch effect correction

## Design matrix. Batch effect will be factored into each contrast of interest.
## A seperate block-design matrix is used to make the comparisions for each
## contrast of interest. This is beacuse the overal design is rank deficient

getBatchDEG <- function(case, control, batch, treatment, x){
  case.ind <- which(as.character(treatment) == case)
  control.ind <- which(as.character(treatment) == control)
  new.treat <- as.character(treatment)[c(case.ind, control.ind)]
  new.treat <- factor(new.treat, levels = unique(new.treat))
  new.treat <- relevel(new.treat,ref=case)
  new.batch <- as.character(batch)[c(case.ind, control.ind)]
  new.batch <- factor(new.batch, levels = unique(new.batch))
  if(length(unique(new.batch)) == 1){
    new.design <- model.matrix(~new.treat)
    colnames(new.design) <- c('Intercept', control)
  }else{
    new.design <- model.matrix(~new.batch+new.treat)
    colnames(new.design) <- c('Intercept', 'batch', control)
  }
  
  new.x <- x[,c(case.ind, control.ind)]
  new.y <- DGEList(counts=new.x, group=new.treat)
  new.y <- calcNormFactors(new.y)
  new.y <- estimateDisp(new.y, new.design, robust=TRUE)
  #new.y$common.dispersion
  #plotBCV(new.y)
  
  
  fit <- glmQLFit(new.y, new.design, robust=TRUE)
  #qlf <- glmQLFTest(fit, coef=2)
  #cpm(new.y)[top,]
  #topTags(qlf)
  #FDR <- p.adjust(qlf$table$PValue, method="BH")
  #sum(FDR < 0.05)
  
  qlf <- glmQLFTest(fit)
  tt <- topTags(qlf, n = nrow(new.y$counts))
  tt <- tt$table[, c('logFC', 'FDR')]
  tt <- tt %>% tibble::rownames_to_column('GeneName')
  
  cont1 <- paste(strsplit(case, split='\\.')[[1]][2], 
                 strsplit(case, split='\\.')[[1]][1], sep='.')
  cont2 <- paste(strsplit(control, split='\\.')[[1]][2], 
                 strsplit(control, split='\\.')[[1]][1], sep='.')
  
  category <- paste(strsplit(control, split='\\.')[[1]][1], 
                    strsplit(case, split='\\.')[[1]][1], sep = '.vs.')
  tt$Contrast <- paste(cont2, cont1, sep = '.vs.')
  tt$Category <- category
  
  #summary(decideTests(qlf))
  #plotMD(qlf)
  #abline(h=c(-1,1), col="blue")
  
  return(tt)
}


myContrasts <- function(){
  contrasts <- data.frame(case = rep('', 32), control = rep('', 32), stringsAsFactors = F)
  
  ## Extra over Intra (extra.vs.intra)
  contrasts$case[1] <- 'intra.P11';  contrasts$control[1] <- 'extra.P11'
  contrasts$case[2] <- 'intra.P85';  contrasts$control[2] <- 'extra.P85'
  contrasts$case[3] <- 'intra.P148'; contrasts$control[3] <- 'extra.P148'
  
  ## Intra over Intra (intra.vs.intra)
  contrasts$case[4] <- 'intra.P11'; contrasts$control[4] <- 'intra.P85'
  contrasts$case[5] <- 'intra.P11'; contrasts$control[5] <- 'intra.P148'
  contrasts$case[6] <- 'intra.P85'; contrasts$control[6] <- 'intra.P148'
  
  ## Extra over Extra  (extra.vs.extra)
  contrasts$case[7]  <- 'extra.P11';  contrasts$control[7]  <- 'extra.P35'
  contrasts$case[8]  <- 'extra.P11';  contrasts$control[8]  <- 'extra.P55'
  contrasts$case[9]  <- 'extra.P11';  contrasts$control[9]  <- 'extra.P148'
  contrasts$case[10] <- 'extra.P11';  contrasts$control[10] <- 'extra.P210'
  contrasts$case[11] <- 'extra.P35';  contrasts$control[11] <- 'extra.P55'
  contrasts$case[12] <- 'extra.P55';  contrasts$control[12] <- 'extra.P148'
  contrasts$case[13] <- 'extra.P148'; contrasts$control[13] <- 'extra.P210'
  

  
  ## Intra over B P7 (intra.vs.B.intra)
  contrasts$case[14] <- 'intra.P7'; contrasts$control[14] <- 'intra.P11'
  contrasts$case[15] <- 'intra.P7'; contrasts$control[15] <- 'intra.P85'
  contrasts$case[16] <- 'intra.P7'; contrasts$control[16] <- 'intra.P148'
  
  ## Extra over B P7 (extra.vs.B.extra)
  contrasts$case[17] <- 'extra.P7';  contrasts$control[17] <- 'extra.P11'
  contrasts$case[18] <- 'extra.P7';  contrasts$control[18] <- 'extra.P55'
  contrasts$case[19] <- 'extra.P7';  contrasts$control[19] <- 'extra.P148'
  contrasts$case[20] <- 'extra.P7';  contrasts$control[20] <- 'extra.P210'
  
  
  ## RH over RH (RH.vs.RH)
  contrasts$case[21] <- 'intra.RH'; contrasts$control[21] <- 'extra.RH'
  
  ## RH over Intra (RH.vs.intra)
  contrasts$case[22] <- 'intra.P11';  contrasts$control[22] <- 'intra.RH';
  contrasts$case[23] <- 'intra.P85';  contrasts$control[23] <- 'intra.RH'
  contrasts$case[24] <- 'intra.P148'; contrasts$control[24] <- 'intra.RH'
  
  ## RH over Extra (RH.vs.extra)
  contrasts$case[25] <- 'extra.P11';  contrasts$control[25] <- 'extra.RH'
  contrasts$case[26] <- 'extra.P35';  contrasts$control[26] <- 'extra.RH'
  contrasts$case[27] <- 'extra.P55';  contrasts$control[27] <- 'extra.RH';
  contrasts$case[28] <- 'extra.P148'; contrasts$control[28] <- 'extra.RH';
  contrasts$case[29] <- 'extra.P210'; contrasts$control[29] <- 'extra.RH'
  
  ## RH over B P7 (RH.vs.B)
  contrasts$case[30] <- 'intra.P7';  contrasts$control[30] <- 'intra.RH'
  contrasts$case[31] <- 'extra.P7';  contrasts$control[31] <- 'extra.RH'

  ## B P7 over B P7 (B.extra.vs.B.intra)
  contrasts$case[32] <- 'intra.P7';  contrasts$control[32] <- 'extra.P7'

  return(contrasts)
}

contrasts <- myContrasts()
all.tabs <- apply(contrasts, 1, function(cc) list(getBatchDEG(cc[1], cc[2], batch, treatment, x)))
all.tabs <- lapply(all.tabs, `[[`, 1)
all.tabs <- do.call('rbind', all.tabs)


## Calculating expression (mean, sd and per replicate and adding to DEG table)
## Should we calculate RPKMs? Gene lengths are needed for that.
logCPM_no_batch <- logCPM_no_batch %>% data.frame() %>% tibble::rownames_to_column('GeneName')
#CPM_no_batch <- logCPM_no_batch %>% mutate_if(is.numeric, funs(exp(.))) 
logFC <- all.tabs %>% dplyr::select(-c('Category', 'FDR')) %>% spread(key = Contrast, value = logFC)
colnames(logFC)[2:ncol(logFC)] <- paste(colnames(logFC)[2:ncol(logFC)], '_log_fc')
FDR <- all.tabs %>% dplyr::select(-c('Category', 'logFC')) %>% spread(key = Contrast, value = FDR)
colnames(FDR)[2:ncol(FDR)] <- paste(colnames(FDR)[2:ncol(FDR)], '_qval')
logFC_FDR <- left_join(logFC, FDR, by = 'GeneName')

logCPM_no_batch_mean_sd <- logCPM_no_batch %>% gather(key = cols, value = Expr, -GeneName) %>% 
  mutate(rep = gsub('.*\\.rep(.*)', "rep\\1", cols), 
         cond = ifelse(str_detect(cols, 'extra'), 'extra',  'intra'),
         Passage = gsub('\\.intra.*', '', gsub('\\.extra.*', '', cols))) %>% dplyr::select(-c('cols'))
logCPM_no_batch_mean_sd <- logCPM_no_batch_mean_sd %>% group_by(GeneName, Passage, cond) %>% 
  summarise(mean = mean(Expr), sd = sd(Expr))
logCPM_no_batch_mean <- logCPM_no_batch_mean_sd %>% ungroup() %>% 
  mutate(Name = paste(Passage, cond, sep = '.')) %>%
  dplyr::select(-c('Passage', 'cond', 'sd')) %>% spread(key=Name, value=mean)
colnames(logCPM_no_batch_mean)[2:ncol(logCPM_no_batch_mean)] <- 
  paste(colnames(logCPM_no_batch_mean)[2:ncol(logCPM_no_batch_mean)], 'mean', sep = '_')

logCPM_no_batch_sd <- logCPM_no_batch_mean_sd %>% ungroup() %>% 
  mutate(Name = paste(Passage, cond, sep = '.')) %>%
  dplyr::select(-c('Passage', 'cond', 'mean')) %>% spread(key=Name, value=sd)
colnames(logCPM_no_batch_sd)[2:ncol(logCPM_no_batch_sd)] <- 
  paste(colnames(logCPM_no_batch_sd)[2:ncol(logCPM_no_batch_sd)], 'sd', sep = '_')
logCPM_no_batch_mean_sd <- left_join(logCPM_no_batch_mean, logCPM_no_batch_sd, by = 'GeneName')
logCPM_no_batch <- left_join(logCPM_no_batch, logCPM_no_batch_mean_sd, by = 'GeneName')
logCPM_no_batch <- logCPM_no_batch[, sort(colnames(logCPM_no_batch), index.return = T)$ix]


## double check with previous results
old.tab.file <- paste(abs.path, 'old_pipeline.xlsx', sep = '')
toxo_tab.old <- read.xlsx(old.tab.file)
colnames(toxo_tab.old) <- gsub("fold.change", 'fold_change', gsub("qValue", 'q_value', colnames(toxo_tab.old)))

toxo_tab.old <- toxo_tab.old %>% dplyr::select(-contains("B4")) %>% 
  dplyr::select(-contains("freshlyse"))
colnames(toxo_tab.old) <- gsub('over', 'vs',gsub('6hes', 'extra',
                                                 gsub('B\\.', '', 
                                                      gsub('B2\\.', '',colnames(toxo_tab.old)))))

toxo.old.fc   <- toxo_tab.old %>% dplyr::select(c(1, contains('fold_change')))
colnames(toxo.old.fc) <- gsub("_log2.fold_change.", "", colnames(toxo.old.fc))
toxo.old.qval <- toxo_tab.old %>% dplyr::select(c(1, contains('q-value')))
colnames(toxo.old.qval) <- gsub("_q-value", "", colnames(toxo.old.qval))

toxo.old.fc <- toxo.old.fc  %>% gather(key = Contrast, value = fc, -GeneName)
toxo.old.qval <- toxo.old.qval  %>% gather(key = Contrast, value = qval, -GeneName)

categories <- gsub("RH.intra", "RH",
                   gsub("RH.extra", "RH", 
                        gsub("^P.*[[:digit:]]\\.", "", 
                             gsub("\\.P.*[[:digit:]]\\.", "\\.", 
                                  gsub('P7', 'B', as.character(toxo.old.fc$Contrast))))))

## Switch intra vs RH to RH vs intra 
switch.ind1 <- which(categories == 'intra.vs.RH')
toxo.old.fc$Contrast[switch.ind1] <- paste(unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind1], split = '.vs.'), `[[`,2)),
                                           unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind1], split = '.vs.'), `[[`,1)),
                                           sep = '.vs.')
toxo.old.qval$Contrast[switch.ind1] <- toxo.old.fc$Contrast[switch.ind1]

categories[switch.ind1] <- 'RH.vs.intra'
toxo.old.fc$fc <- as.numeric(toxo.old.fc$fc)
toxo.old.fc$fc[switch.ind1] <- -toxo.old.fc$fc[switch.ind1]
toxo.old.qval$qval <- as.numeric(toxo.old.qval$qval)

## Switch intra vs extra to extra vs intra
switch.ind2 <- which(categories == 'intra.vs.extra')
toxo.old.fc$Contrast[switch.ind2] <- paste(unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind2], split = '.vs.'), `[[`,2)),
                                           unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind2], split = '.vs.'), `[[`,1)),
                                           sep = '.vs.')
toxo.old.qval$Contrast[switch.ind2] <- toxo.old.fc$Contrast[switch.ind2]

categories[switch.ind2] <- 'extra.vs.intra'
toxo.old.fc$fc[switch.ind2] <- -toxo.old.fc$fc[switch.ind2]


## Switch extra vs RH to RH vs extra 
switch.ind3 <- which(categories == 'extra.vs.RH')
toxo.old.fc$Contrast[switch.ind3] <- paste(unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind3], split = '.vs.'), `[[`,2)),
                                           unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind3], split = '.vs.'), `[[`,1)),
                                           sep = '.vs.')
toxo.old.qval$Contrast[switch.ind3] <- toxo.old.fc$Contrast[switch.ind3]

categories[switch.ind3] <- 'RH.vs.extra'
toxo.old.fc$fc <- as.numeric(toxo.old.fc$fc)
toxo.old.fc$fc[switch.ind3] <- -toxo.old.fc$fc[switch.ind3]
toxo.old.qval$qval <- as.numeric(toxo.old.qval$qval)

## Switch P7 vs RH to RH vs P7 
switch.ind4 <- which(categories == 'B.extra.vs.RH')
toxo.old.fc$Contrast[switch.ind4] <- paste(unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind4], split = '.vs.'), `[[`,2)),
                                           unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind4], split = '.vs.'), `[[`,1)),
                                           sep = '.vs.')
toxo.old.qval$Contrast[switch.ind4] <- toxo.old.fc$Contrast[switch.ind4]

categories[switch.ind4] <- 'RH.vs.B.extra'
toxo.old.fc$fc <- as.numeric(toxo.old.fc$fc)
toxo.old.fc$fc[switch.ind4] <- -toxo.old.fc$fc[switch.ind4]
toxo.old.qval$qval <- as.numeric(toxo.old.qval$qval)

## Switch P7 intra over P11 intra to P11 inta vs P7 intra
switch.ind5 <- which(categories == "B.intra.vs.intra")
toxo.old.fc$Contrast[switch.ind5] <- paste(unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind5], split = '.vs.'), `[[`,2)),
                                           unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind5], split = '.vs.'), `[[`,1)),
                                           sep = '.vs.')
toxo.old.qval$Contrast[switch.ind5] <- toxo.old.fc$Contrast[switch.ind5]

categories[switch.ind5] <- "intra.vs.B.intra"
toxo.old.fc$fc <- as.numeric(toxo.old.fc$fc)
toxo.old.fc$fc[switch.ind5] <- -toxo.old.fc$fc[switch.ind5]
toxo.old.qval$qval <- as.numeric(toxo.old.qval$qval)

# Switch P7.intra.vs.P7.extra to P7.extra.vs.P7.intra 
switch.ind6 <- which(categories == "B.intra.vs.B.extra")
toxo.old.fc$Contrast[switch.ind6] <- paste(unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind6], split = '.vs.'), `[[`,2)),
                                           unlist(lapply(strsplit(toxo.old.fc$Contrast[switch.ind6], split = '.vs.'), `[[`,1)),
                                           sep = '.vs.')
toxo.old.qval$Contrast[switch.ind6] <- toxo.old.fc$Contrast[switch.ind6]

categories[switch.ind6] <- "B.extra.vs.B.intra"
toxo.old.fc$fc <- as.numeric(toxo.old.fc$fc)
toxo.old.fc$fc[switch.ind6] <- -toxo.old.fc$fc[switch.ind5]
toxo.old.qval$qval <- as.numeric(toxo.old.qval$qval)

#categories <- factor(categories, levels = unique(categories))
toxo.old.fc$Category <- categories
#toxo.old.fc$Contrast <- factor(toxo.old.fc$Contrast, levels = unique(toxo.old.fc$Contrast))
#toxo.old.qval$Contrast <- factor(toxo.old.qval$Contrast, levels = unique(toxo.old.qval$Contrast))


toxo.old.fc.qval <- inner_join(toxo.old.fc, toxo.old.qval, by = c('GeneName', 'Contrast'))
toxo.old.fc.qval <- toxo.old.fc.qval %>% na.omit()
toxo.old.fc.qval$Contrast <- gsub('P145', 'P148', gsub('P84', 'P85', toxo.old.fc.qval$Contrast))



XX <- left_join(all.tabs, toxo.old.fc.qval, by = c('GeneName', 'Contrast'))
XX.summary <- XX %>% na.omit() %>% group_by(Contrast) %>% summarise(DEG1 = sum(FDR < 0.05 & abs(logFC) > 0.58), 
                                                                    DEG2 = sum(qval < 0.05 & abs(fc) > 0.58), 
                                                                    comon = sum(FDR < 0.05 & abs(logFC) > 0.58 & qval < 0.05 & abs(fc) > 0.58 ))


new.stats <- all.tabs %>% na.omit() %>% group_by(Contrast) %>% 
  summarise(DEG1 = sum(FDR < 0.05 & abs(logFC) > 0.58))

#colnames(toxo_tab.old)
#logCPM_no_batch$GeneName
toxo_tab <- right_join(logCPM_no_batch, logFC_FDR, by = 'GeneName')
out.deg.file <- paste(abs.path, 'toxo_table_batch_corrected_logCPM_expression_edgeR_DEGs.xlsx', sep = '')
write.xlsx(toxo_tab, out.deg.file)


#### Adding AP2 Info (other info should be added?)
old.tab.file <- paste(abs.path, 'old_pipeline.xlsx', sep = '')
toxo_tab.old <- read.xlsx(old.tab.file)
new.tab.file <- paste(abs.path, 'toxo_table_batch_corrected_logCPM_expression_edgeR_DEGs.xlsx', sep = '')

toxo_tab.old <- read.xlsx(old.tab.file)
toxo_tab.new <- read.xlsx(new.tab.file)


xx <- left_join(toxo_tab.new, toxo_tab.old, by = 'GeneName')

xx <- xx %>% 
  dplyr::select(c(colnames(toxo_tab.new), 'Product.Description', colnames(xx)[grep('AP2', colnames(xx))])) %>%
  dplyr::select(-contains('Adjusted')) %>% dplyr::select(-contains('Peak'))


out.deg.file <- paste(abs.path, 'toxo_table_batch_corrected_logCPM_expression_edgeR_DEGs_ap2_targs.xlsx', sep = '')
write.xlsx(xx, out.deg.file)
